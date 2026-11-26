#!/usr/bin/env bash
# Acquire authenticated Kylin headers before installing the full toolchain.
set -Eeuo pipefail
trap 'echo "Kylin CI failed at line $LINENO: $BASH_COMMAND" >&2' ERR
test "$(uname -m)" = aarch64
export DEBIAN_FRONTEND=noninteractive
apt_options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=35 -o Acquire::https::Timeout=35)
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends ca-certificates curl python3 gnupg gpgv
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 scripts/arm64/resolve-kylin-headers.py --self-test
python3 scripts/arm64/resolve-kylin-headers.py --work "$work" \
  --suite "${KYLIN_APT_SUITE:-auto}" --version "${KYLIN_PACKAGE_VERSION:-}"
version="$(cat "$work/headers/VERSION")"
apt-get "${apt_options[@]}" install -y --no-install-recommends \
  build-essential gcc-9 g++-9 binutils file kmod libelf-dev libssl-dev \
  libncurses-dev pkg-config bc tar gzip git cpio bison flex
# Extract into separate isolated roots. Kylin and Ubuntu can use different
# usrmerge layouts and package-level symlinks; extracting to / can destroy
# the host's compiler or basic tools. Install ONLY the expected header trees.
gcc-9 --version
rm --version | sed -n '1p'
install -d /usr/src
for package in linux-headers-5.4.18-53 linux-headers-5.4.18-53-generic; do
  deb="$work/headers/$package.deb"
  stage="$(mktemp -d "$work/stage.XXXXXX")"
  echo "Extracting authenticated $package into an isolated staging directory"
  dpkg-deb -x "$deb" "$stage"
  source="$stage/usr/src/$package"
  dest="/usr/src/$package"
  # Require real directories inside the staging root, not top-level symlinks.
  [[ -d "$source" && ! -L "$source" ]] || { echo "Expected header tree not present: $source" >&2; find "$stage" -maxdepth 4 -type d -name 'linux-headers-*' -print; exit 1; }
  [[ "$(realpath -e "$source")" = "$(realpath -e "$stage")/usr/src/$package" ]] || { echo "Header tree escapes staging root" >&2; exit 1; }
  [[ ! -e "$dest" && ! -L "$dest" ]] || { echo "Unexpected existing header tree: $dest" >&2; exit 1; }
  # Keep links between common and flavor trees at their original /usr/src
  # locations; do not merge any other package paths into the build container.
  cp -a -- "$source" "$dest"
  echo "Installed isolated kernel header tree: $dest"
  gcc-9 --version | sed -n '1p'
  rm --version | sed -n '1p'
done
export KDIR=/usr/src/linux-headers-5.4.18-53-generic
export KERNEL_HEADERS_PACKAGE_VERSION="$version"
export CC=gcc-9
for f in Makefile Module.symvers include/config/auto.conf include/generated/utsrelease.h; do
  [[ -s "$KDIR/$f" ]] || { echo "Missing or unresolved prepared kernel file: $KDIR/$f" >&2; exit 1; }
done
printf 'Prepared Kylin header release: '
cat "$KDIR/include/generated/utsrelease.h"
gcc-9 --version
curl --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$work/rustup-init.sh"
sh "$work/rustup-init.sh" -y --profile minimal --default-toolchain 1.90.0
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add aarch64-unknown-none-softfloat
bash scripts/arm64/build-kylin.sh
