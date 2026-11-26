#!/usr/bin/env bash
# Isolated build container: use Kylin's official signed APT metadata for
# exact headers, but obtain ordinary build tools from the Ubuntu Focal image.
set -Eeuo pipefail
trap 'echo "Kylin CI failed at line $LINENO: $BASH_COMMAND" >&2' ERR
test "$(uname -m)" = aarch64
export DEBIAN_FRONTEND=noninteractive
apt_options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=35 -o Acquire::https::Timeout=35)
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends \
  build-essential gcc-9 g++-9 binutils ca-certificates curl file kmod libelf-dev libssl-dev \
  libncurses-dev pkg-config python3 bc tar gzip git gnupg gpgv cpio bison flex
archive=https://archive.kylinos.cn/kylin/KYLIN-ALL
suite="${KYLIN_APT_SUITE:-10.1}"
case "$suite" in 10.0|10.1|10.1-2107-updates|10.1-2203-updates) ;; *) echo 'Unsupported Kylin suite' >&2; exit 1;; esac
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 755 "$work"
fetch() {
  curl --proto '=https' --proto-redir '=https' --location --fail --silent --show-error \
    --connect-timeout 15 --max-time 90 --retry 1 "$@"
}
# The initial trust anchor is the vendor's own HTTPS keyring package.
# Optional independently verified SHA256 can pin this bootstrap package.
keybase="$archive/pool/main/k/kylin-keyring"
fetch "$keybase/" -o "$work/keyring-index.html"
mapfile -t keys < <(python3 - "$work/keyring-index.html" <<'PY'
import re,sys
from html.parser import HTMLParser
class Index(HTMLParser):
    def __init__(self):
        super().__init__(); self.names=set()
    def handle_starttag(self,tag,attrs):
        if tag!='a': return
        href=dict(attrs).get('href','')
        if re.fullmatch(r'kylin-keyring_[A-Za-z0-9.+~_-]+_(all|arm64)\.deb',href):
            self.names.add(href)
p=Index(); p.feed(open(sys.argv[1],encoding='utf-8',errors='replace').read())
print('\n'.join(sorted(p.names)))
PY
)
keyfile="$(printf '%s\n' "${keys[@]}" | sed '/^$/d' | sort -V | tail -n 1)"
[[ -n "$keyfile" ]] || { echo 'Official Kylin keyring package was not found; obtain vendor keyring through an approved channel.' >&2; exit 1; }
fetch "$keybase/$keyfile" -o "$work/keyring.deb"
echo "Official keyring package: $keyfile"
sha256sum "$work/keyring.deb"
if [[ -n "${KYLIN_KEYRING_SHA256:-}" ]]; then
  [[ "$KYLIN_KEYRING_SHA256" =~ ^[[:xdigit:]]{64}$ ]]
  printf '%s  %s\n' "$KYLIN_KEYRING_SHA256" "$work/keyring.deb" | sha256sum -c -
fi
[[ "$(dpkg-deb -f "$work/keyring.deb" Package)" = kylin-keyring ]]
dpkg-deb -x "$work/keyring.deb" "$work/keyring"
mkdir -m 700 "$work/gnupg"
mapfile -t keyrings < <(find "$work/keyring" -type f \
  \( -path '*/usr/share/keyrings/*.gpg' -o -path '*/usr/share/keyrings/*.asc' -o -path '*/etc/apt/trusted.gpg.d/*.gpg' -o -path '*/etc/apt/trusted.gpg.d/*.asc' \) \
  ! -iname '*removed*' ! -iname '*revoked*' ! -iname '*obsolete*')
[[ "${#keyrings[@]}" -gt 0 ]] || { echo 'No active keyring files in vendor package' >&2; exit 1; }
for key in "${keyrings[@]}"; do
  gpg --batch --homedir "$work/gnupg" --import "$key"
done
gpg --batch --homedir "$work/gnupg" --fingerprint
gpg --batch --homedir "$work/gnupg" --export > "$work/kylin.gpg"
test -s "$work/kylin.gpg"
chmod 644 "$work/kylin.gpg"
mkdir "$work/lists" "$work/debs"
printf 'deb [arch=arm64 signed-by=%s] %s %s main\n' "$work/kylin.gpg" "$archive" "$suite" > "$work/kylin.list"
kapt=("${apt_options[@]}" -o "Dir::Etc::sourcelist=$work/kylin.list" \
  -o Dir::Etc::sourceparts=- -o "Dir::State::lists=$work/lists" -o APT::Architecture=arm64)
# Never use trusted=yes or permit unauthenticated packages.
apt-get "${kapt[@]}" update
common=linux-headers-5.4.18-53
flavor=linux-headers-5.4.18-53-generic
version="${KYLIN_PACKAGE_VERSION:-$(apt-cache "${kapt[@]}" policy "$flavor:arm64" | awk '/Candidate:/ {print $2; exit}')}"
[[ "$version" =~ ^5\.4\.18-53\.[0-9]+([A-Za-z0-9.+~:-]*)$ ]] || {
  echo "Exact Kylin header package unavailable in signed suite $suite (candidate: $version)" >&2
  exit 1
}
echo "Authenticated Kylin headers revision: $version"
# Fetch only the paired header packages from the signed Kylin index.
# Ubuntu packages with a similar version are never used as substitutes.
(
  cd "$work/debs"
  apt-get "${kapt[@]}" download "$common=$version" "$flavor:arm64=$version"
)
for package in "$common" "$flavor"; do
  mapfile -t debs < <(find "$work/debs" -maxdepth 1 -type f -name "${package}_*.deb")
  [[ "${#debs[@]}" -eq 1 ]] || { echo "Expected one $package package" >&2; exit 1; }
  deb="${debs[0]}"
  [[ "$(dpkg-deb -f "$deb" Package)" = "$package" ]]
  [[ "$(dpkg-deb -f "$deb" Version)" = "$version" ]]
  arch="$(dpkg-deb -f "$deb" Architecture)"
  if [[ "$package" = "$flavor" ]]; then [[ "$arch" = arm64 ]]; else [[ "$arch" = all || "$arch" = arm64 ]]; fi
  spec="$package=$version"
  if [[ "$arch" = arm64 ]]; then spec="$package:arm64=$version"; fi
  hash="$(apt-cache "${kapt[@]}" show "$spec" | awk '/^SHA256: /{print $2}' | sort -u)"
  [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || { echo "Missing or ambiguous signed SHA-256 for $spec" >&2; exit 1; }
  printf '%s  %s\n' "$hash" "$deb" | sha256sum -c -
  # Extract into the disposable container only; don't execute vendor maintainer scripts.
  dpkg-deb -x "$deb" /
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
