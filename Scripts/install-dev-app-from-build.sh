#!/usr/bin/env bash
set -euo pipefail

SOURCE_APP="${1:-${TARGET_BUILD_DIR:-}/${FULL_PRODUCT_NAME:-}}"
DEST_APP="${KEYTYPE_DEV_APP_PATH:-/Applications/KeyType Dev.app}"
DEV_APP_NAME="${KEYTYPE_DEV_APP_NAME:-KeyType Dev}"
DEV_BUNDLE_ID="${KEYTYPE_DEV_BUNDLE_ID:-com.pattonium.KeyType.dev}"

if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
  echo "warning: KeyType dev install skipped; source app not found at $SOURCE_APP"
  exit 0
fi

case "$SOURCE_APP" in
  *.app) ;;
  *) exit 0 ;;
esac

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sign_identity="$("$scripts/dev-signing-identity.sh")"
if [[ "$DEV_BUNDLE_ID" != com.pattonium.KeyType.dev || "$DEST_APP" == */KeyType.app || -L "$DEST_APP" ]]; then
  echo "Refusing to install outside the KeyType Dev identity." >&2
  exit 1
fi
if [[ -e "$DEST_APP" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST_APP/Contents/Info.plist")" != "$DEV_BUNDLE_ID" ]]; then
  echo "Destination is not a KeyType Dev installation." >&2
  exit 1
fi
DEST_PARENT="$(dirname "$DEST_APP")"
mkdir -p "$DEST_PARENT"
stage="$(mktemp -d "$DEST_PARENT/.keytype-dev-install.XXXXXXXX")"
cleanup() {
  # Retain the backup if installation and rollback both fail.
  if [[ ! -e "$stage/previous" ]]; then rm -rf "$stage"; fi
}
trap cleanup EXIT
candidate="$stage/KeyType Dev.app"
ditto "$SOURCE_APP" "$candidate"

INFO_PLIST="$candidate/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DEV_APP_NAME" "$INFO_PLIST"
if /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$INFO_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DEV_APP_NAME" "$INFO_PLIST"
else
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DEV_APP_NAME" "$INFO_PLIST"
fi

# Sign nested executable code first; a resource-only bundle needs no signing identity.
while IFS= read -r -d '' component; do
  /usr/bin/codesign --force --sign "$sign_identity" --options runtime "$component"
done < <(find "$candidate/Contents" -depth \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -o -type f -name '*.dylib' \) -print0)
codesign --force --sign "$sign_identity" --identifier "$DEV_BUNDLE_ID" --options runtime \
  --entitlements "$scripts/../KeyType/KeyType.entitlements" "$candidate"
codesign --verify --deep --strict "$candidate"
requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^.*designated => //p'
}
new_requirement="$(requirement "$candidate")"
[[ "$new_requirement" == *"anchor apple"* && "$new_requirement" == *"$DEV_BUNDLE_ID"* ]] || {
  echo "The candidate does not have the expected Apple-signed development identity." >&2; exit 1;
}
if [[ -d "$DEST_APP" ]]; then
  old_requirement="$(requirement "$DEST_APP")"
  if [[ "$old_requirement" != cdhash* ]]; then
    codesign --verify -R "=$old_requirement" "$candidate"
    codesign --verify -R "=$new_requirement" "$DEST_APP"
  fi
fi

PLIST_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")"
SIGNED_BUNDLE_ID="$(codesign -dv "$candidate" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$PLIST_BUNDLE_ID" != "$DEV_BUNDLE_ID" || "$SIGNED_BUNDLE_ID" != "$DEV_BUNDLE_ID" ]]; then
  echo "error: installed dev app identity mismatch" >&2
  echo "  Info.plist: $PLIST_BUNDLE_ID" >&2
  echo "  codesign:   $SIGNED_BUNDLE_ID" >&2
  echo "  expected:   $DEV_BUNDLE_ID" >&2
  exit 1
fi

if [[ -d "$DEST_APP" ]]; then
  exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$DEST_APP/Contents/Info.plist")"
  pid="$(ps -axo pid=,comm= | awk -v exe="$DEST_APP/Contents/MacOS/$exe" '{p=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0==exe) print p}')"
  if [[ -n "$pid" ]]; then
    kill -TERM "$pid"
    for ((i=0;i<40;i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$pid" 2>/dev/null; then echo "KeyType Dev is still running." >&2; exit 1; fi
  fi
  mv "$DEST_APP" "$stage/previous"
fi
if ! mv "$candidate" "$DEST_APP"; then
  if [[ -d "$stage/previous" ]]; then mv "$stage/previous" "$DEST_APP"; fi
  exit 1
fi
if [[ -d "$stage/previous" ]]; then
  if [[ -n ${KEYTYPE_DEV_BACKUP_DIR:-} ]]; then
    backup="$KEYTYPE_DEV_BACKUP_DIR/Previous-KeyType-Dev-$(date '+%Y%m%d-%H%M%S')-$$.staged"
    mv "$stage/previous" "$backup" || echo "Previous Dev build retained at $stage/previous" >&2
  else
    rm -rf "$stage/previous"
  fi
fi
touch "$DEST_APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
fi

echo "Installed $DEST_APP ($DEV_BUNDLE_ID)"
