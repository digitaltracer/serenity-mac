#!/usr/bin/env python3
"""Register Swift files in Serenity.xcodeproj for both app targets.

Usage: add_pbx_files.py <group-path-under-Serenity> <file1.swift> [file2.swift ...]
Example: add_pbx_files.py Shared/UI/Sections/Today TodaySectionView.swift

Creates missing PBXGroup nodes along the path (matching the folder layout)
and adds each file to the SerenityMac and SerenityIOS Sources phases.
"""
import re
import sys

PBXPROJ = "Serenity.xcodeproj/project.pbxproj"
PREFIX = "A00000000000000000000"  # project uses synthetic sequential IDs

def main():
    group_path, files = sys.argv[1], sys.argv[2:]
    src = open(PBXPROJ).read()

    used = {int(m, 16) for m in re.findall(re.escape(PREFIX) + r"([0-9A-F]{3})", src)}
    next_id = [max(used) + 1]

    def fresh():
        while next_id[0] in used:
            next_id[0] += 1
        used.add(next_id[0])
        return PREFIX + format(next_id[0], "03X")

    def group_block(gid):
        m = re.search(re.escape(gid) + r" /\* [^*]* \*/ = \{\s*isa = PBXGroup;.*?\};", src, re.S)
        return m

    # Walk the group path from the Serenity root group, creating as needed.
    # Roots: Shared=A...004? Find by name walking from top: locate group whose path = first component.
    def find_child_group(parent_block, name):
        m = re.search(r"(" + re.escape(PREFIX) + r"[0-9A-F]{3}) /\* " + re.escape(name) + r" \*/", parent_block)
        return m.group(1) if m else None

    # find the group with `path = <name>;` reachable by walking components
    components = group_path.split("/")
    # start: find the 'Serenity' source-root group: the group containing child named components[0]
    cur_gid = None
    for m in re.finditer(re.escape(PREFIX) + r"[0-9A-F]{3}(?= /\* " + re.escape(components[0]) + r" \*/ = \{)", src):
        cur_gid = m.group(0)
        break
    assert cur_gid, f"root group {components[0]} not found"

    for comp in components[1:]:
        blk = group_block(cur_gid)
        assert blk, cur_gid
        child = find_child_group(blk.group(0), comp)
        if child and f"{child} /* {comp} */ = {{" in src:
            cur_gid = child
            continue
        # create the group
        gid = fresh()
        new_group = (
            f"\t\t{gid} /* {comp} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n"
            f"\t\t\t);\n"
            f"\t\t\tpath = {comp};\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};\n"
        )
        # insert group def right after parent block, and child ref into parent children
        parent = group_block(cur_gid).group(0)
        new_parent = parent.replace("children = (\n", f"children = (\n\t\t\t\t{gid} /* {comp} */,\n", 1)
        src = src.replace(parent, new_parent + "\n" + new_group.rstrip("\n"), 1)
        cur_gid = gid

    # add file refs + build files
    ref_section_anchor = "/* End PBXFileReference section */"
    build_section_anchor = "/* End PBXBuildFile section */"
    mac_sources = re.search(
        r"files = \(\n((?:.*\n)*?)\t\t\t\);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\};\n\t\tA000000000000000000000C8",
        src)
    # More robust: find the two PBXSourcesBuildPhase blocks
    phases = list(re.finditer(r"isa = PBXSourcesBuildPhase;.*?files = \(\n(.*?)\t\t\t\);", src, re.S))
    assert len(phases) == 2, f"expected 2 source phases, got {len(phases)}"

    for name in files:
        ref = fresh()
        macb = fresh()
        iosb = fresh()
        src = src.replace(
            ref_section_anchor,
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n{ref_section_anchor}",
            1,
        )
        src = src.replace(
            build_section_anchor,
            f"\t\t{macb} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n"
            f"\t\t{iosb} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n{build_section_anchor}",
            1,
        )
        # group child
        parent = group_block(cur_gid).group(0)
        new_parent = parent.replace("children = (\n", f"children = (\n\t\t\t\t{ref} /* {name} */,\n", 1)
        src = src.replace(parent, new_parent, 1)
        # sources phases (first = mac, second = iOS by project layout)
        phases = list(re.finditer(r"(isa = PBXSourcesBuildPhase;.*?files = \(\n)", src, re.S))
        src = src[:phases[0].end()] + f"\t\t\t\t{macb} /* {name} in Sources */,\n" + src[phases[0].end():]
        phases = list(re.finditer(r"(isa = PBXSourcesBuildPhase;.*?files = \(\n)", src, re.S))
        src = src[:phases[1].end()] + f"\t\t\t\t{iosb} /* {name} in Sources */,\n" + src[phases[1].end():]

    open(PBXPROJ, "w").write(src)
    print(f"registered {len(files)} file(s) under {group_path}")

if __name__ == "__main__":
    main()
