#!/bin/sh
# Refreshes the Material Icons font and the list of Flutter's Icons names the design kit uses, from a Flutter SDK.
# Usage: scripts/update-design-icons.sh [/path/to/flutter]   (defaults to the flutter on PATH)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
sdk=${1:-$(dirname "$(dirname "$(command -v flutter)")")}
out="$here/MobileStudio/Resources/Design"
cp "$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf" "$out/"
cp "$sdk/bin/cache/artifacts/material_fonts/MaterialIcons_LICENSE.txt" "$out/"
# Flutter's own codepoints file is older than icons.dart, so read the names from the code Flutter compiles.
python3 -I - "$sdk/packages/flutter/lib/src/material/icons.dart" "$out/icon-codepoints.txt" <<'PY'
import re, sys
source = open(sys.argv[1]).read()
pairs = sorted(set(re.findall(r"static const IconData (\w+) = IconData\(\s*0x([0-9a-f]+),\s*fontFamily: 'MaterialIcons'", source)))
open(sys.argv[2], "w").writelines(f"{name} {point}\n" for name, point in pairs)
print(len(pairs), "icons")
PY
