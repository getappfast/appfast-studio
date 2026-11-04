#!/bin/sh
# Refreshes the Google Fonts catalog the design step checks font names against.
# Usage: scripts/update-google-fonts.sh   (needs network; writes MobileStudio/Resources/Design/google-fonts.json)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp)
curl -sf -o "$tmp" https://fonts.google.com/metadata/fonts
python3 -I - "$tmp" "$here/MobileStudio/Resources/Design/google-fonts.json" <<'PY'
import json, sys
families = json.load(open(sys.argv[1]))["familyMetadataList"]
out = [{"family": f["family"], "category": f["category"], "styles": sorted(f["fonts"].keys())} for f in families]
json.dump(sorted(out, key=lambda f: f["family"].lower()), open(sys.argv[2], "w"), separators=(",", ":"))
print(len(out), "families")
PY
rm -f "$tmp"
