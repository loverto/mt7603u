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
for package in linux-headers-5.4.18-53 linux-headers-5.4.18-53-generic; do
  # Already authenticated by the resolver. Do not run vendor package scripts.
  dpkg-deb -x "$work/headers/$package.deb" /
done
export KDIR=/usr/src/linux-headers-5.4.18-53-generic
export KERNEL_HEADERS_PACKAGE_VERSION="$version"
export CC=gcc-9
gcc-9 --version
curl --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$work/rustup-init.sh"
sh "$work/rustup-init.sh" -y --profile minimal --default-toolchain 1.90.0
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add aarch64-unknown-none-softfloat
bash scripts/arm64/build-kylin.sh
