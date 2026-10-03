#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]] ||
   ! command -v pacman >/dev/null || ! command -v makepkg >/dev/null; then
  echo 'Build on x86_64 Arch Linux with base-devel installed.' >&2
  exit 1
fi
if (( EUID == 0 )); then
  echo 'Run this script as a normal user; makepkg must not run as root.' >&2
  exit 1
fi
if (( $# != 0 )); then
  echo 'Usage: bash tools/arch/build-arch.sh' >&2
  exit 1
fi
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$project_dir"
flutter_bin=${FLUTTER_BIN:-flutter}
for tool in clang++ cmake ninja pkg-config readelf sha256sum zstd fakeroot; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
pkg-config --exists gtk+-3.0 mpv libsecret-1 webkit2gtk-4.1 ayatana-appindicator3-0.1 libpulse-mainloop-glib || {
  echo 'Install gtk3, mpv, libsecret, webkit2gtk-4.1, libayatana-appindicator and libpulse before building.' >&2; exit 1;
}
pacman -Q mimalloc >/dev/null || { echo 'Install mimalloc before building.' >&2; exit 1; }

version=$(sed -nE 's/^version: *([^[:space:]]+).*/\1/p' pubspec.yaml)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$ ]] || {
  echo 'Expected a numeric release version in pubspec.yaml.' >&2; exit 1;
}
"$flutter_bin" pub get --enforce-lockfile
"$flutter_bin" build linux --release --no-pub --target-platform linux-x64
bundle="$project_dir/build/linux/x64/release/bundle"
# Pin the allocator's ABI so a future major upgrade cannot silently break startup.
mimalloc_abi=$(readelf -d "$bundle/qingting" |
  sed -nE 's/.*Shared library: \[libmimalloc\.so\.([0-9]+)\].*/\1/p')
[[ $mimalloc_abi =~ ^[0-9]+$ ]] || {
  echo 'Could not determine the linked mimalloc ABI.' >&2; exit 1;
}
linked_libraries=$(ldd "$bundle/qingting")
if [[ $linked_libraries == *'not found'* ]]; then
  echo 'The executable has unresolved libraries; build in a clean Arch checkout.' >&2
  exit 1
fi

mkdir -p "$project_dir/build/arch" "$project_dir/dist"
staging=$(mktemp -d "$project_dir/build/arch/package.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "$staging/payload/qingting"
cp -a "$bundle/." "$staging/payload/qingting/"
cp tools/linux/com.pobb.qingting.desktop tools/linux/qingting.png \
  tools/linux/README.txt "$staging/payload/"
archive="qingting-${version}-arch-x86_64-bundle.tar.gz"
tar -C "$staging/payload" -czf "$staging/$archive" .
digest=$(sha256sum "$staging/$archive")
digest=${digest%% *}
sed -e "s/@VERSION@/$version/g" \
  -e "s/@SHA256@/$digest/g" \
  -e "s/@MIMALLOC_ABI@/$mimalloc_abi/g" \
  -e "s/@MIMALLOC_NEXT_ABI@/$((mimalloc_abi + 1))/g" \
  tools/arch/PKGBUILD.in > "$staging/PKGBUILD"
(
  cd "$staging"
  # Do not install packages or alter the host during packaging.
  PKGDEST="$staging" makepkg --clean --noconfirm
)
package="qingting-${version}-1-x86_64.pkg.tar.zst"
test -f "$staging/$package"
install -m 644 "$staging/$package" "$project_dir/dist/$package"
(
  cd "$project_dir/dist"
  sha256sum "$package" > "$package.sha256"
)
echo "Created dist/$package"
