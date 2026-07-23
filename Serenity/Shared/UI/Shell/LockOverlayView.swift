import SwiftUI

/// Full-window lock screen shown until the local lock is unlocked.
struct LocalLockOverlayView: View {
  @EnvironmentObject private var appState: AppState
  @State private var password = ""
  @State private var revealPassword = false
  @State private var isUnlockingWithPassword = false
  @State private var isUnlockingWithBiometrics = false
  @FocusState private var passwordFieldFocused: Bool

  var body: some View {
    VStack(spacing: SerenityUI.Spacing.xl) {
      Spacer()

      VStack(spacing: SerenityUI.Spacing.xs) {
        Image(systemName: "lock")
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(SerenityPalette.accent)

        Text("Serenity Notes")
          .font(.title2.weight(.semibold))
          .foregroundStyle(SerenityPalette.textPrimary)

        Text("Enter your master password to unlock")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
          Text("Master Password")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)

          HStack(spacing: SerenityUI.Spacing.xs) {
            Group {
              if revealPassword {
                TextField("Enter master password", text: $password)
              } else {
                SecureField("Enter master password", text: $password)
              }
            }
            .textFieldStyle(.plain)
            .focused($passwordFieldFocused)
            .submitLabel(.go)
            .onSubmit {
              unlockWithPassword()
            }
            .disabled(isLockedOut || isUnlockingWithPassword)

            Button {
              revealPassword.toggle()
            } label: {
              Image(systemName: revealPassword ? "eye.slash" : "eye")
                .foregroundStyle(SerenityPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
            .disabled(isLockedOut || isUnlockingWithPassword)
          }
          .serenityInputField()
        }

        if let lockoutMessage {
          statusMessage(lockoutMessage, tint: .red)
        } else if let attemptsWarning {
          statusMessage(attemptsWarning, tint: .orange)
        }

        Button {
          unlockWithPassword()
        } label: {
          HStack(spacing: SerenityUI.Spacing.xs) {
            if isUnlockingWithPassword {
              ProgressView()
                .controlSize(.small)
              Text("Validating...")
            } else {
              Text(isLockedOut ? "Locked" : "Unlock")
            }
          }
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .disabled(unlockDisabled)
        .opacity(unlockDisabled ? 0.5 : 1)

        if isBiometricAvailable {
          Button {
            unlockWithBiometrics()
          } label: {
            HStack(spacing: SerenityUI.Spacing.xs) {
              if isUnlockingWithBiometrics {
                ProgressView()
                  .controlSize(.small)
                Text("Authenticating...")
              } else {
                Label("Use Touch ID", systemImage: "touchid")
              }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .disabled(isUnlockingWithBiometrics || isUnlockingWithPassword || isLockedOut)

          HStack(spacing: SerenityUI.Spacing.xs) {
            VStack { Divider() }
            Text("or")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
            VStack { Divider() }
          }
        }

        Button("Forgot your password?") {
          appState.requestSettings(tab: .general)
          appState.showToast("After unlocking, open Settings to reset your local lock password.")
        }
        .buttonStyle(.plain)
        .font(SerenityType.bodyMedium)
        .foregroundStyle(SerenityPalette.accent)
        .frame(maxWidth: .infinity, alignment: .center)

        HStack(alignment: .firstTextBaseline, spacing: SerenityUI.Spacing.xxs) {
          Image(systemName: "shield")
          Text("All sensitive information is encrypted with your master password.")
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(SerenityPalette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .center)
      }
      .frame(maxWidth: 360)

      Spacer()

      Text("Serenity Notes v2.0 • Privacy-First Productivity")
        .font(.caption2)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
    .padding(SerenityUI.Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SerenityPalette.windowBackground.ignoresSafeArea())
    .onAppear {
      passwordFieldFocused = true
    }
  }

  private var unlockDisabled: Bool {
    password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLockedOut || isUnlockingWithPassword || isUnlockingWithBiometrics
  }

  private var isLockedOut: Bool {
    if case .lockedOut = appState.localLockStatus {
      return true
    }
    return false
  }

  private var isBiometricAvailable: Bool {
    if case .available = appState.biometricAvailability {
      return true
    }
    return false
  }

  private var attemptsWarning: String? {
    guard case .locked(let attemptsRemaining) = appState.localLockStatus else { return nil }
    guard attemptsRemaining < 5 else { return nil }
    if attemptsRemaining == 1 {
      return "Last attempt before temporary lockout"
    }
    return "\(attemptsRemaining) attempts remaining"
  }

  private var lockoutMessage: String? {
    guard case .lockedOut(let until) = appState.localLockStatus else { return nil }
    let remainingSeconds = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
    if remainingSeconds <= 0 {
      return "Too many failed attempts. Try again shortly."
    }
    return "Too many failed attempts. Try again in \(formattedDuration(seconds: remainingSeconds))."
  }

  private func formattedDuration(seconds: Int) -> String {
    let minutes = seconds / 60
    let remainder = seconds % 60
    if minutes > 0 {
      return "\(minutes)m \(remainder)s"
    }
    return "\(remainder)s"
  }

  private func statusMessage(_ text: String, tint: Color) -> some View {
    Label {
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
    }
    .font(.footnote)
    .foregroundStyle(tint)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func unlockWithPassword() {
    guard !unlockDisabled else { return }

    let submitted = password.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !submitted.isEmpty else { return }

    isUnlockingWithPassword = true
    Task {
      await appState.unlockAppWithPassword(submitted)
      if case .unlocked = appState.localLockStatus {
        password = ""
      }
      isUnlockingWithPassword = false
    }
  }

  private func unlockWithBiometrics() {
    guard isBiometricAvailable else { return }
    guard !isUnlockingWithBiometrics else { return }

    isUnlockingWithBiometrics = true
    Task {
      await appState.unlockAppWithBiometrics()
      isUnlockingWithBiometrics = false
    }
  }
}
