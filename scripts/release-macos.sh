#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'EOF'
Build, sign, package, notarize, and staple a macOS release for Serenity.

Usage:
  scripts/release-macos.sh \
    [--format zip|dmg|pkg|both|all] \
    --team-id <TEAM_ID> \
    --developer-id-app-cert "<Developer ID Application cert name>" \
    [--developer-id-installer-cert "<Developer ID Installer cert name>"] \
    [--notary-profile <keychain-profile>] \
    [--project <path-to-xcodeproj>] \
    [--scheme <scheme>] \
    [--configuration Release] \
    [--output-dir <dist-dir>] \
    [--dmg-volume-name <name>] \
    [--profile-main <profile-name>] \
    [--app-bundle-id <bundle-id>] \
    [--google-client-id <client-id>] \
    [--google-reversed-client-id <reversed-client-id>] \
    [--skip-notarization] \
    [--allow-provisioning-updates] \
    [--env-file <path>]

Examples:
  scripts/release-macos.sh --skip-notarization --format zip
  scripts/release-macos.sh --env-file scripts/release-macos.env
  scripts/release-macos.sh --env-file scripts/release-macos.env --format all

Notes:
  - If scripts/release-macos.env exists, it is loaded automatically by default.
  - Default format is pkg if --format is omitted.
  - A notarization ZIP is always produced.
  - zip: notarized/stapled app + zip artifact
  - dmg: zip + dmg
  - pkg: zip + pkg
  - both/all: zip + dmg + pkg
  - For pkg/both/all, --developer-id-installer-cert is required.
  - For notarization, --notary-profile is required unless --skip-notarization is set.
EOF
}

info() {
    echo "==> $*"
}

die() {
    echo "error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

parse_bool() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) echo "true" ;;
        0|false|FALSE|no|NO|off|OFF|"") echo "false" ;;
        *) die "Invalid boolean value: $1" ;;
    esac
}

decode_profile_plist() {
    local profile_path="$1"
    openssl smime -inform der -verify -noverify -in "${profile_path}" 2>/dev/null || true
}

plist_read() {
    local plist_content="$1"
    local key_path="$2"
    /usr/libexec/PlistBuddy -c "Print ${key_path}" /dev/stdin <<<"${plist_content}" 2>/dev/null || true
}

find_developer_id_profile_name() {
    local bundle_id="$1"
    local wanted_appid="${TEAM_ID}.${bundle_id}"
    local wildcard_appid="${TEAM_ID}.*"
    local profile_dirs=(
        "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
        "$HOME/Library/MobileDevice/Provisioning Profiles"
    )

    local exact_all_devices_name=""
    local exact_name=""
    local wildcard_name=""
    local dir file plist name appid appid_alt candidate_appid profile_team all_devices
    for dir in "${profile_dirs[@]}"; do
        [[ -d "${dir}" ]] || continue
        for file in "${dir}"/*.provisionprofile "${dir}"/*.mobileprovision; do
            [[ -e "${file}" ]] || continue
            plist="$(decode_profile_plist "${file}")"
            [[ -n "${plist}" ]] || continue

            name="$(plist_read "${plist}" ':Name')"
            profile_team="$(plist_read "${plist}" ':TeamIdentifier:0')"
            appid="$(plist_read "${plist}" ':Entitlements:application-identifier')"
            appid_alt="$(plist_read "${plist}" ':Entitlements:com.apple.application-identifier')"
            all_devices="$(plist_read "${plist}" ':ProvisionsAllDevices')"
            candidate_appid="${appid:-${appid_alt}}"

            [[ "${profile_team}" == "${TEAM_ID}" ]] || continue
            [[ "${candidate_appid}" == "${wanted_appid}" || "${candidate_appid}" == "${wildcard_appid}" ]] || continue
            [[ -n "${name}" ]] || continue

            if [[ "${candidate_appid}" == "${wanted_appid}" ]]; then
                if [[ "${all_devices}" == "true" && -z "${exact_all_devices_name}" ]]; then
                    exact_all_devices_name="${name}"
                elif [[ -z "${exact_name}" ]]; then
                    exact_name="${name}"
                fi
            elif [[ "${candidate_appid}" == "${wildcard_appid}" && -z "${wildcard_name}" ]]; then
                wildcard_name="${name}"
            fi
        done
    done

    [[ -n "${exact_all_devices_name}" ]] && { echo "${exact_all_devices_name}"; return 0; }
    [[ -n "${exact_name}" ]] && { echo "${exact_name}"; return 0; }
    [[ -n "${wildcard_name}" ]] && { echo "${wildcard_name}"; return 0; }
    return 1
}

contains_runtime_flag() {
    local binary_path="$1"
    local codesign_output=""
    local line=""
    local code_directory_line=""

    if ! codesign_output="$(codesign -d --verbose=4 "${binary_path}" 2>&1)"; then
        return 1
    fi

    while IFS= read -r line; do
        if [[ "${line}" == CodeDirectory* ]]; then
            code_directory_line="${line}"
            break
        fi
    done <<< "${codesign_output}"

    [[ -n "${code_directory_line}" ]] || return 1
    [[ "${code_directory_line}" == *"(runtime)"* ]]
}

check_hardened_runtime() {
    local binary_path="$1"
    local label="$2"

    [[ -f "${binary_path}" ]] || die "Expected executable not found for ${label}: ${binary_path}"
    if ! contains_runtime_flag "${binary_path}"; then
        die "${label} is not signed with Hardened Runtime: ${binary_path}"
    fi
}

submit_for_notarization() {
    local artifact_path="$1"
    local result_log="$2"
    local artifact_name
    artifact_name="$(basename "${artifact_path}")"

    info "Submitting for notarization: ${artifact_name}"
    if ! xcrun notarytool submit \
        "${artifact_path}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait \
        --output-format json | tee "${result_log}"; then
        die "Notarization submission command failed for ${artifact_name}. See ${result_log}"
    fi

    local status
    status="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${result_log}" | head -n 1)"
    if [[ "${status}" != "Accepted" ]]; then
        local submission_id
        submission_id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${result_log}" | head -n 1)"
        if [[ -n "${submission_id}" ]]; then
            local detail_log
            detail_log="${LOGS_DIR}/notary-detail-${artifact_name}.json"
            info "Notarization status for ${artifact_name}: ${status:-unknown}. Fetching detailed log..."
            xcrun notarytool log "${submission_id}" --keychain-profile "${NOTARY_PROFILE}" | tee "${detail_log}" >/dev/null
            die "Notarization failed for ${artifact_name}. See ${result_log} and ${detail_log}"
        fi
        die "Notarization failed for ${artifact_name}. See ${result_log}"
    fi
}

nonfatal_spctl_assess() {
    local target_path="$1"
    local log_path="$2"
    if ! spctl -a -vv "${target_path}" | tee "${log_path}"; then
        info "Gatekeeper assessment returned non-zero for ${target_path}. Continuing; notarization status remains authoritative."
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_PATH="${PROJECT_PATH:-}"
SCHEME="${SCHEME:-}"
CONFIGURATION="${CONFIGURATION:-}"
FORMAT="${FORMAT:-}"
TEAM_ID="${TEAM_ID:-}"
DEVELOPER_ID_APP_CERT="${DEVELOPER_ID_APP_CERT:-}"
DEVELOPER_ID_INSTALLER_CERT="${DEVELOPER_ID_INSTALLER_CERT:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-}"
PROFILE_MAIN="${PROFILE_MAIN:-}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.digitaltracer.serenity}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_REVERSED_CLIENT_ID="${GOOGLE_REVERSED_CLIENT_ID:-}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-}"
ENV_FILE=""
DEFAULT_ENV_FILE="${SCRIPT_DIR}/release-macos.env"

ARGS=("$@")

for ((i = 0; i < ${#ARGS[@]}; i++)); do
    if [[ "${ARGS[$i]}" == "--env-file" ]]; then
        ((i + 1 < ${#ARGS[@]})) || die "Missing value for --env-file"
        ENV_FILE="${ARGS[$((i + 1))]}"
        break
    fi
done

if [[ -z "${ENV_FILE}" && -f "${DEFAULT_ENV_FILE}" ]]; then
    ENV_FILE="${DEFAULT_ENV_FILE}"
fi

if [[ -n "${ENV_FILE}" ]]; then
    [[ -f "${ENV_FILE}" ]] || die "Env file not found: ${ENV_FILE}"
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

PROJECT_PATH="${PROJECT_PATH:-${RELEASE_PROJECT_PATH:-}}"
SCHEME="${SCHEME:-${RELEASE_SCHEME:-}}"
CONFIGURATION="${CONFIGURATION:-${RELEASE_CONFIGURATION:-}}"
FORMAT="${FORMAT:-${RELEASE_FORMAT:-}}"
TEAM_ID="${TEAM_ID:-${RELEASE_TEAM_ID:-}}"
DEVELOPER_ID_APP_CERT="${DEVELOPER_ID_APP_CERT:-${RELEASE_DEVELOPER_ID_APP_CERT:-}}"
DEVELOPER_ID_INSTALLER_CERT="${DEVELOPER_ID_INSTALLER_CERT:-${RELEASE_DEVELOPER_ID_INSTALLER_CERT:-}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-${RELEASE_NOTARY_PROFILE:-}}"
OUTPUT_DIR="${OUTPUT_DIR:-${RELEASE_OUTPUT_DIR:-}}"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-${RELEASE_DMG_VOLUME_NAME:-}}"
PROFILE_MAIN="${PROFILE_MAIN:-${RELEASE_PROFILE_MAIN:-}}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-${RELEASE_APP_BUNDLE_ID:-}}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-${RELEASE_GOOGLE_CLIENT_ID:-}}"
GOOGLE_REVERSED_CLIENT_ID="${GOOGLE_REVERSED_CLIENT_ID:-${RELEASE_GOOGLE_REVERSED_CLIENT_ID:-}}"
MARKETING_VERSION="${MARKETING_VERSION:-${RELEASE_MARKETING_VERSION:-}}"
BUILD_NUMBER="${BUILD_NUMBER:-${RELEASE_BUILD_NUMBER:-}}"
if [[ -z "${SKIP_NOTARIZATION:-}" ]]; then
    SKIP_NOTARIZATION="${RELEASE_SKIP_NOTARIZATION:-false}"
fi
if [[ -z "${ALLOW_PROVISIONING_UPDATES:-}" ]]; then
    ALLOW_PROVISIONING_UPDATES="${RELEASE_ALLOW_PROVISIONING_UPDATES:-false}"
fi

i=0
while ((i < ${#ARGS[@]})); do
    arg="${ARGS[$i]}"
    case "${arg}" in
        --format) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --format"; FORMAT="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --team-id) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --team-id"; TEAM_ID="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --developer-id-app-cert) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --developer-id-app-cert"; DEVELOPER_ID_APP_CERT="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --developer-id-installer-cert) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --developer-id-installer-cert"; DEVELOPER_ID_INSTALLER_CERT="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --notary-profile) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --notary-profile"; NOTARY_PROFILE="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --project) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --project"; PROJECT_PATH="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --scheme) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --scheme"; SCHEME="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --configuration) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --configuration"; CONFIGURATION="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --output-dir) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --output-dir"; OUTPUT_DIR="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --dmg-volume-name) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --dmg-volume-name"; DMG_VOLUME_NAME="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --profile-main) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --profile-main"; PROFILE_MAIN="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --app-bundle-id) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --app-bundle-id"; APP_BUNDLE_ID="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --google-client-id) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --google-client-id"; GOOGLE_CLIENT_ID="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --google-reversed-client-id) ((i + 1 < ${#ARGS[@]})) || die "Missing value for --google-reversed-client-id"; GOOGLE_REVERSED_CLIENT_ID="${ARGS[$((i + 1))]}"; i=$((i + 2)) ;;
        --skip-notarization) SKIP_NOTARIZATION="true"; i=$((i + 1)) ;;
        --allow-provisioning-updates) ALLOW_PROVISIONING_UPDATES="true"; i=$((i + 1)) ;;
        --env-file) i=$((i + 2)) ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: ${arg}" ;;
    esac
done

PROJECT_PATH="${PROJECT_PATH:-${REPO_ROOT}/Serenity.xcodeproj}"
SCHEME="${SCHEME:-SerenityMac}"
CONFIGURATION="${CONFIGURATION:-Release}"
FORMAT="${FORMAT:-pkg}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/dist}"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-Serenity}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.digitaltracer.serenity}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%y%m%d%H%M)}"
SKIP_NOTARIZATION="$(parse_bool "${SKIP_NOTARIZATION}")"
ALLOW_PROVISIONING_UPDATES="$(parse_bool "${ALLOW_PROVISIONING_UPDATES}")"

case "${FORMAT}" in
    zip|dmg|pkg|both|all) ;;
    *) die "--format must be one of: zip, dmg, pkg, both, all" ;;
esac

[[ -n "${TEAM_ID}" ]] || die "--team-id is required"
[[ -n "${DEVELOPER_ID_APP_CERT}" ]] || die "--developer-id-app-cert is required"
[[ -e "${PROJECT_PATH}" ]] || die "Project file not found: ${PROJECT_PATH}"

INCLUDE_DMG="false"
INCLUDE_PKG="false"
case "${FORMAT}" in
    dmg) INCLUDE_DMG="true" ;;
    pkg) INCLUDE_PKG="true" ;;
    both|all) INCLUDE_DMG="true"; INCLUDE_PKG="true" ;;
esac

if [[ "${INCLUDE_PKG}" == "true" ]]; then
    [[ -n "${DEVELOPER_ID_INSTALLER_CERT}" ]] || die "--developer-id-installer-cert is required for pkg/both/all"
fi

if [[ "${SKIP_NOTARIZATION}" == "false" ]]; then
    [[ -n "${NOTARY_PROFILE}" ]] || die "--notary-profile is required unless --skip-notarization is set"
fi

require_cmd xcodebuild
require_cmd xcrun
require_cmd codesign
require_cmd spctl
require_cmd security
require_cmd ditto
require_cmd openssl
require_cmd /usr/libexec/PlistBuddy

if [[ "${INCLUDE_DMG}" == "true" ]]; then
    require_cmd hdiutil
fi

if [[ "${INCLUDE_PKG}" == "true" ]]; then
    require_cmd pkgbuild
    require_cmd productbuild
fi

if ! security find-identity -v -p codesigning | grep -Fq "${DEVELOPER_ID_APP_CERT}"; then
    die "Developer ID Application certificate not found in keychain: ${DEVELOPER_ID_APP_CERT}"
fi

if [[ "${INCLUDE_PKG}" == "true" ]]; then
    if ! security find-identity -v -p basic | grep -Fq "${DEVELOPER_ID_INSTALLER_CERT}"; then
        die "Developer ID Installer certificate not found in keychain: ${DEVELOPER_ID_INSTALLER_CERT}"
    fi
fi

PROFILE_MAIN="${PROFILE_MAIN:-$(find_developer_id_profile_name "${APP_BUNDLE_ID}" || true)}"
PROVISIONING_PROFILES_PLIST=""
if [[ -n "${PROFILE_MAIN}" ]]; then
    PROVISIONING_PROFILES_PLIST="
    <key>provisioningProfiles</key>
    <dict>
        <key>${APP_BUNDLE_ID}</key>
        <string>${PROFILE_MAIN}</string>
    </dict>"
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
WORK_DIR="${OUTPUT_DIR}/release-${timestamp}"
ARCHIVE_PATH="${WORK_DIR}/${SCHEME}.xcarchive"
EXPORT_DIR="${WORK_DIR}/export"
ARTIFACTS_DIR="${WORK_DIR}/artifacts"
LOGS_DIR="${WORK_DIR}/logs"
EXPORT_OPTIONS_PLIST="${WORK_DIR}/ExportOptions.plist"

mkdir -p "${WORK_DIR}" "${EXPORT_DIR}" "${ARTIFACTS_DIR}" "${LOGS_DIR}"

cat > "${EXPORT_OPTIONS_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
${PROVISIONING_PROFILES_PLIST}
</dict>
</plist>
EOF

xcode_archive_cmd=(
    xcodebuild archive
    -project "${PROJECT_PATH}"
    -scheme "${SCHEME}"
    -configuration "${CONFIGURATION}"
    -destination "generic/platform=macOS"
    -archivePath "${ARCHIVE_PATH}"
    DEVELOPMENT_TEAM="${TEAM_ID}"
    CODE_SIGN_STYLE=Automatic
    MARKETING_VERSION="${MARKETING_VERSION}"
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"
    PRODUCT_BUNDLE_IDENTIFIER="${APP_BUNDLE_ID}"
)

if [[ -n "${GOOGLE_CLIENT_ID}" ]]; then
    xcode_archive_cmd+=(GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID}")
fi
if [[ -n "${GOOGLE_REVERSED_CLIENT_ID}" ]]; then
    xcode_archive_cmd+=(GOOGLE_REVERSED_CLIENT_ID="${GOOGLE_REVERSED_CLIENT_ID}")
fi

xcode_export_cmd=(
    xcodebuild -exportArchive
    -archivePath "${ARCHIVE_PATH}"
    -exportPath "${EXPORT_DIR}"
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"
)

if [[ "${ALLOW_PROVISIONING_UPDATES}" == "true" ]]; then
    xcode_archive_cmd+=(-allowProvisioningUpdates)
    xcode_export_cmd+=(-allowProvisioningUpdates)
fi

info "Archiving app..."
"${xcode_archive_cmd[@]}" 2>&1 | tee "${LOGS_DIR}/archive.log"

info "Exporting signed app for Developer ID distribution..."
"${xcode_export_cmd[@]}" 2>&1 | tee "${LOGS_DIR}/export.log"

APP_PATH="$(find "${EXPORT_DIR}" -maxdepth 3 -type d -name "*.app" | head -n 1)"
[[ -n "${APP_PATH}" ]] || die "Could not find exported .app in ${EXPORT_DIR}"

APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_INFO_PLIST}" 2>/dev/null || echo "unknown")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_INFO_PLIST}" 2>/dev/null || echo "0")"
ARTIFACT_BASE="${SCHEME}-${APP_VERSION}-${APP_BUILD}"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${APP_INFO_PLIST}" 2>/dev/null || true)"
[[ -n "${APP_EXECUTABLE}" ]] || die "Could not read CFBundleExecutable from ${APP_INFO_PLIST}"
APP_BINARY_PATH="${APP_PATH}/Contents/MacOS/${APP_EXECUTABLE}"

info "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" | tee "${LOGS_DIR}/codesign-verify.log"
codesign -d --verbose=4 "${APP_BINARY_PATH}" 2>&1 | tee "${LOGS_DIR}/codesign-main-details.log" >/dev/null
check_hardened_runtime "${APP_BINARY_PATH}" "Main app executable"
nonfatal_spctl_assess "${APP_PATH}" "${LOGS_DIR}/spctl-pre-notary.log"

declare -a ARTIFACT_PATHS=()
declare -a STAPLE_AFTER_NOTARY_PATHS=()

ZIP_PATH="${ARTIFACTS_DIR}/${ARTIFACT_BASE}.zip"
info "Creating distributable ZIP..."
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}" | tee "${LOGS_DIR}/zip-create.log"
ARTIFACT_PATHS+=("${ZIP_PATH}")

if [[ "${INCLUDE_DMG}" == "true" ]]; then
    DMG_STAGING_DIR="${WORK_DIR}/dmg-staging"
    DMG_PATH="${ARTIFACTS_DIR}/${ARTIFACT_BASE}.dmg"

    rm -rf "${DMG_STAGING_DIR}"
    mkdir -p "${DMG_STAGING_DIR}"
    cp -R "${APP_PATH}" "${DMG_STAGING_DIR}/"
    ln -s /Applications "${DMG_STAGING_DIR}/Applications"

    info "Creating DMG package..."
    hdiutil create \
        -volname "${DMG_VOLUME_NAME}" \
        -srcfolder "${DMG_STAGING_DIR}" \
        -format UDZO \
        -ov \
        "${DMG_PATH}" | tee "${LOGS_DIR}/dmg-create.log"

    ARTIFACT_PATHS+=("${DMG_PATH}")
    STAPLE_AFTER_NOTARY_PATHS+=("${DMG_PATH}")
fi

if [[ "${INCLUDE_PKG}" == "true" ]]; then
    PKG_PATH="${ARTIFACTS_DIR}/${ARTIFACT_BASE}.pkg"
    COMPONENT_PKG_PATH="${WORK_DIR}/${ARTIFACT_BASE}-component.pkg"

    info "Creating component PKG payload..."
    pkgbuild \
        --component "${APP_PATH}" \
        --install-location /Applications \
        --identifier "${APP_BUNDLE_ID}.installer" \
        --version "${APP_BUILD}" \
        "${COMPONENT_PKG_PATH}" | tee "${LOGS_DIR}/pkgbuild-create.log"

    info "Creating signed PKG package..."
    productbuild \
        --package "${COMPONENT_PKG_PATH}" \
        --sign "${DEVELOPER_ID_INSTALLER_CERT}" \
        "${PKG_PATH}" | tee "${LOGS_DIR}/pkg-create.log"

    ARTIFACT_PATHS+=("${PKG_PATH}")
    STAPLE_AFTER_NOTARY_PATHS+=("${PKG_PATH}")
fi

if [[ "${SKIP_NOTARIZATION}" == "false" ]]; then
    info "Submitting artifacts for notarization using profile: ${NOTARY_PROFILE}"
    for artifact in "${ARTIFACT_PATHS[@]}"; do
        artifact_name="$(basename "${artifact}")"
        result_log="${LOGS_DIR}/notary-${artifact_name}.json"
        submit_for_notarization "${artifact}" "${result_log}"
    done

    info "Stapling notarization ticket to app bundle..."
    xcrun stapler staple "${APP_PATH}" | tee "${LOGS_DIR}/staple-app.log"
    xcrun stapler validate "${APP_PATH}" | tee "${LOGS_DIR}/staple-validate-app.log"
    nonfatal_spctl_assess "${APP_PATH}" "${LOGS_DIR}/spctl-post-notary.log"

    for artifact in "${STAPLE_AFTER_NOTARY_PATHS[@]}"; do
        artifact_name="$(basename "${artifact}")"
        info "Stapling notarization ticket: ${artifact_name}"
        xcrun stapler staple "${artifact}" | tee "${LOGS_DIR}/staple-${artifact_name}.log"
        xcrun stapler validate "${artifact}" | tee "${LOGS_DIR}/staple-validate-${artifact_name}.log"
    done
else
    info "Skipping notarization as requested."
fi

FINAL_ARTIFACT_PATHS=()
for artifact in "${ARTIFACT_PATHS[@]}"; do
    artifact_name="$(basename "${artifact}")"
    final_artifact_path="${OUTPUT_DIR}/${artifact_name}"

    info "Saving final artifact..."
    rm -f "${final_artifact_path}"
    cp "${artifact}" "${final_artifact_path}"
    FINAL_ARTIFACT_PATHS+=("${final_artifact_path}")
done

info "Done."
echo ""
echo "Artifacts:"
for artifact in "${FINAL_ARTIFACT_PATHS[@]}"; do
    echo "  - ${artifact}"
done
echo ""
echo "Work directory:"
echo "  ${WORK_DIR}"
