#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
sha256sum -c SHA256SUMS
test "$(uname -m)" = aarch64 || { echo 'Architecture mismatch'; exit 1; }
expected="$(cat KERNEL_RELEASE)"
actual="$(uname -r)"
test "$actual" = "$expected" || { echo "Kernel mismatch: expected $expected, actual $actual"; exit 1; }
test "$(modinfo -F vermagic ./mt7603u.ko)" = "$(cat VERMAGIC)"
test "$(modinfo -F vermagic ./mt7603u.ko | cut -d ' ' -f1)" = "$actual"
if command -v lsusb >/dev/null; then
  lsusb | grep -Ei '0e8d:(760c|7603)' || echo 'Compatible USB device not currently visible.'
fi
echo 'Architecture, package integrity and kernel release match. Kernel ABI/signature and hardware operation still require on-device verification.'
