#!/bin/zsh
set -eu
root="${0:A:h:h}"
products="$root/.build/release"
"$root/Scripts/dev-signing-identity.sh" > /dev/null
staging="$(mktemp -d "${TMPDIR:-/tmp}/keytype-dev-package.XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/KeyType Dev.app"
destination="${KEYTYPE_DEV_APP_PATH:-/Applications/KeyType Dev.app}"
bundle_id="com.pattonium.KeyType.dev"
test -x "$products/KeyTypeDev"
test ! -e "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
/usr/bin/ditto "$products/KeyTypeDev" "$app/Contents/MacOS/KeyTypeDev"
/usr/bin/ditto "$products/llama.framework" "$app/Contents/Frameworks/llama.framework"
/usr/bin/ditto "$products/SQLCipher.framework" "$app/Contents/Frameworks/SQLCipher.framework"
/usr/bin/ditto "$products/GRDB_GRDB.bundle" "$app/Contents/Resources/GRDB_GRDB.bundle"
/usr/bin/sips -s format icns "$root/.github/images/app-icon.png" --out "$app/Contents/Resources/KeyType.icns" >/dev/null
python3 - "$root/KeyType/Info.plist" "$app/Contents/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
info.update(
    CFBundleDevelopmentRegion='zh-Hans',
    CFBundleExecutable='KeyTypeDev',
    CFBundleIdentifier='com.pattonium.KeyType.dev',
    CFBundleName='KeyType Dev',
    CFBundlePackageType='APPL',
    CFBundleShortVersionString='1.8.0',
    CFBundleVersion='2',
    CFBundleIconFile='KeyType',
    LSMinimumSystemVersion='14.0',
)
with open(sys.argv[2], 'wb') as f:
    plistlib.dump(info, f)
PY
/usr/bin/otool -L "$app/Contents/MacOS/KeyTypeDev" | /usr/bin/grep -E '(SQLCipher|llama)'
KEYTYPE_DEV_APP_PATH="$destination" KEYTYPE_DEV_BUNDLE_ID="$bundle_id" "$root/Scripts/install-dev-app-from-build.sh" "$app"
