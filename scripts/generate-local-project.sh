#!/bin/bash
# Generates AICompleteChat.xcodeproj wired to the LOCAL sibling checkouts of AIChatKit,
# AIChatKitMLX, AiPersona and AiVoiceKit instead of their GitHub tags, so package edits are
# picked up by the app and its tests immediately. project.yml is left untouched (it stays
# clone-and-build for everyone else); the local spec is gitignored.
#
# Usage: scripts/generate-local-project.sh   (PKG_ROOT overrides the packages directory)
set -euo pipefail
cd "$(dirname "$0")/.."
PKG_ROOT="${PKG_ROOT:-/Users/nerdsnipe/xCodeProjects/NerdSnipe-Inc-Packages}"

python3 - "$PKG_ROOT" <<'PY'
import re, sys
root = sys.argv[1]
text = open("project.yml").read()
for name in ["AIChatKit", "AIChatKitMLX", "AiPersona", "AiVoiceKit"]:
    pattern = re.compile(rf"^  {name}:\n(?:    #.*\n)*    url: .*\n(?:    (?:from|branch): .*\n)", re.M)
    text, n = pattern.subn(f"  {name}:\n    path: {root}/{name}\n", text)
    assert n == 1, f"could not rewrite package block for {name}"
open("project.local.yml", "w").write(text)
PY

xcodegen generate --spec project.local.yml --quiet
echo "Generated AICompleteChat.xcodeproj against local packages in $PKG_ROOT"
