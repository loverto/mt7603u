#!/usr/bin/env bash
# Build against the exact prepared Kylin kernel, never a renamed generic tree.
set -Eeuo pipefail
trap 'echo "Kylin build failed at line $LINENO: $BASH_COMMAND" >&2' ERR
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
target=5.4.18-53-generic
test "$(uname -m)" = aarch64
export KDIR="$(realpath "${KDIR:-/lib/modules/$target/build}")"
test -s "$KDIR/Module.symvers" || { echo 'Missing exact kernel Module.symvers' >&2; exit 1; }
test -s "$KDIR/include/generated/utsrelease.h"
actual="$(sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' "$KDIR/include/generated/utsrelease.h")"
[[ "$actual" = "$target" ]] || { echo "Kylin target mismatch: $actual != $target" >&2; exit 1; }
conf="$KDIR/include/config/auto.conf"
test -s "$conf" || { echo 'Missing prepared kernel configuration' >&2; exit 1; }
grep -qx 'CONFIG_ARM64=y' "$conf"
grep -Eq '^CONFIG_MAC80211=(y|m)$' "$conf"
grep -Eq '^CONFIG_CFG80211=(y|m)$' "$conf"
printf 'Kylin target: %s\n' "$actual"
grep -E '^(CONFIG_CC_VERSION_TEXT|CONFIG_MODVERSIONS|CONFIG_MODULE_SIG_FORCE)=' "$conf" || true
export BUILD_LABEL=kylin-v10 KERNEL_TARGET_RELEASE="$target"
export SOURCE_COMMIT="${SOURCE_COMMIT:-$(git rev-parse HEAD)}"
cargo test --locked --manifest-path src/rust/Cargo.toml --lib
bash scripts/arm64/build.sh
bash scripts/arm64/package.sh
