#!/usr/bin/env bash
# Separate ARM64 path; leave the upstream x86_64 relocation workaround untouched.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
test "$(uname -m)" = aarch64 || { echo 'Native ARM64 build environment required' >&2; exit 1; }
kdir="$(realpath "${KDIR:-/lib/modules/$(uname -r)/build}")"
test -f "$kdir/Makefile"
test -s "$kdir/Module.symvers" || { echo 'A complete, prepared kernel build tree with Module.symvers is required' >&2; exit 1; }
export CARGO_TARGET_DIR="$root/src/rust/target"
target=aarch64-unknown-none-softfloat
RUSTFLAGS="-C relocation-model=static" cargo build --locked \
  --manifest-path src/rust/Cargo.toml --release --lib --target "$target"
archive="$CARGO_TARGET_DIR/$target/release/libmt7603u_logic.a"
object="$root/src/c/rust_logic.o"
mapfile -t symbols < <(awk '/^[[:space:]]+-u mt7603_rust_/ {print $2}' Makefile)
test "${#symbols[@]}" -gt 0
keep=()
for symbol in "${symbols[@]}"; do keep+=(-u "$symbol"); done
ld -r --gc-sections "${keep[@]}" --whole-archive "$archive" --no-whole-archive -o "$object"
objcopy -R .llvmbc -R .llvmcmd "$object"
readelf -h "$object" | grep -E 'Machine:.*AArch64'
nm --defined-only "$object" > "$root/src/c/rust_logic.symbols"
for symbol in "${symbols[@]}"; do
  grep -Eq "[[:space:]]$symbol$" "$root/src/c/rust_logic.symbols"
done
# Kbuild 5.10 and newer use different saved-command variable names.
printf 'cmd_%s := true\nsavedcmd_%s := true\n' "$object" "$object" > "$root/src/c/.rust_logic.o.cmd"
make -C "$kdir" M="$root" ARCH=arm64 modules
test -s mt7603u.ko
readelf -h mt7603u.ko | grep -E 'Machine:.*AArch64'
release="$(make -s -C "$kdir" ARCH=arm64 kernelrelease)"
vermagic="$(modinfo -F vermagic ./mt7603u.ko)"
test "${vermagic%% *}" = "$release"
modinfo -F alias ./mt7603u.ko | grep -i 'v0E8Dp760C'
modinfo -F alias ./mt7603u.ko | grep -i 'v0E8Dp7603'
printf 'Built ARM64 module for %s (%s)\n' "$release" "$vermagic"
