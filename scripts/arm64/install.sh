#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
test "$(id -u)" -eq 0 || { echo 'Run with authorized administrator privileges.' >&2; exit 1; }
bash check.sh
dest="/lib/modules/$(uname -r)/updates/mt7603u.ko"
firmware="/lib/firmware/mt7603u.bin"
expected="$(cat FIRMWARE_SHA256)"
hash() { sha256sum "$1" | cut -d ' ' -f1; }
if [[ -e "$dest" || -L "$dest" ]]; then
  [[ -f "$dest" && ! -L "$dest" && "$(hash "$dest")" = "$(hash mt7603u.ko)" ]] || { echo "Refusing to overwrite existing module: $dest" >&2; exit 1; }
fi
if [[ -e "$firmware" || -L "$firmware" ]]; then
  [[ -f "$firmware" && "$(hash "$firmware")" = "$expected" ]] || { echo 'Existing firmware differs; refusing to overwrite.' >&2; exit 1; }
else
  supplied="${1:-}"
  [[ -n "$supplied" && -f "$supplied" && "$(hash "$supplied")" = "$expected" ]] || { echo 'Supply the authorized reference firmware as the first argument; SHA-256 must match FIRMWARE_SHA256.' >&2; exit 1; }
  install -m 0644 "$supplied" "$firmware"
fi
if [[ ! -e "$dest" ]]; then install -D -m 0644 mt7603u.ko "$dest"; fi
depmod -a
echo 'Installed. Load only when authorized: modprobe mt7603u'
echo 'If module signing or ABI checks reject the module, contact the system administrator; do not disable security controls.'
