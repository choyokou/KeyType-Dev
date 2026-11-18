#!/bin/bash
# Both development installers resolve the same certificate. Store only its public fingerprint.
set -euo pipefail
pin_dir="$HOME/Library/Application Support/KeyType Dev/Signing"
pin_file="$pin_dir/apple-development.sha1"
if [[ ${1:-} == --pin ]]; then
    fingerprint=${2:?Expected Apple Development certificate fingerprint}
else
    if [[ ! -r "$pin_file" ]]; then
        echo "KeyType Dev requires a pinned Apple Development certificate. Run Scripts/dev-signing-identity.sh --pin FINGERPRINT first." >&2
        exit 1
    fi
    IFS= read -r fingerprint < "$pin_file"
fi
if ! [[ "$fingerprint" =~ ^[A-F0-9]{40}$ ]] ||
   ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v fp="$fingerprint" '$2 == fp && /"Apple Development: / {found=1} END {exit !found}'; then
    echo "The pinned Apple Development signing identity is unavailable. Check Xcode and the login keychain." >&2
    exit 1
fi
if [[ ${1:-} == --pin ]]; then
    umask 077
    mkdir -p "$pin_dir"
    if [[ -e "$pin_file" && "$(cat "$pin_file")" != "$fingerprint" ]]; then
        echo "A different certificate is already pinned. Review the signing identity before changing it." >&2
        exit 1
    fi
    printf '%s\n' "$fingerprint" > "$pin_file"
fi
printf '%s\n' "$fingerprint"
