#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
  echo 'Build this package on Linux (or inside WSL Ubuntu).' >&2
  exit 1
fi
make_deb=false
if [[ ${1:-} == --deb && $# == 1 ]]; then
  make_deb=true
elif [[ $# != 0 ]]; then
  echo 'Usage: bash tools/linux/build-linux.sh [--deb]' >&2
  exit 1
fi
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$project_dir"
flutter_bin=${FLUTTER_BIN:-flutter}
case $(uname -m) in
  x86_64) flutter_arch=x64; deb_arch=amd64 ;;
  aarch64) flutter_arch=arm64; deb_arch=arm64 ;;
  *) echo 'Supported build hosts: x86_64 and aarch64.' >&2; exit 1 ;;
esac
for tool in cmake ninja clang++ pkg-config tar; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
pkg-config --exists gtk+-3.0 mpv || {
  echo 'Install libgtk-3-dev and libmpv-dev before building.' >&2
  exit 1
}
if $make_deb; then
  for tool in dpkg-deb dpkg-shlibdeps; do
    command -v "$tool" >/dev/null || { echo "Install dpkg-dev for --deb." >&2; exit 1; }
  done
fi

"$flutter_bin" pub get --enforce-lockfile
"$flutter_bin" build linux --release --no-pub --target-platform "linux-$flutter_arch"
version=$(sed -nE 's/^version: *([^[:space:]]+).*/\1/p' pubspec.yaml)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$ ]] || {
  echo 'Expected a numeric release version in pubspec.yaml.' >&2; exit 1;
}
bundle="$project_dir/build/linux/$flutter_arch/release/bundle"
package_name="QingTing-v${version}-linux-${flutter_arch}"
mkdir -p "$project_dir/dist"
staging=$(mktemp -d "$project_dir/build/linux/package.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "$staging/$package_name"
cp -a "$bundle/." "$staging/$package_name/"
cp tools/linux/README.txt "$staging/$package_name/README.txt"
tar -C "$staging" -czf "$project_dir/dist/$package_name.tar.gz" "$package_name"
echo "Created dist/$package_name.tar.gz"

if $make_deb; then
  deb_root="$staging/deb"
  mkdir -p "$deb_root/opt/qingting" "$deb_root/usr/bin" \
    "$deb_root/usr/share/applications" "$deb_root/usr/share/icons/hicolor/192x192/apps" \
    "$deb_root/DEBIAN" "$staging/debian"
  cp -a "$bundle/." "$deb_root/opt/qingting/"
  cp tools/linux/README.txt "$deb_root/opt/qingting/README.txt"
  ln -s /opt/qingting/qingting "$deb_root/usr/bin/qingting"
  install -m 644 tools/linux/com.pobb.qingting.desktop "$deb_root/usr/share/applications/"
  install -m 644 tools/linux/qingting.png "$deb_root/usr/share/icons/hicolor/192x192/apps/com.pobb.qingting.png"
  printf 'Source: qingting\n\nPackage: qingting\nArchitecture: %s\nDescription: QingTing music player\n' \
    "$deb_arch" > "$staging/debian/control"
  # Inspect every bundled ELF: Flutter and plugins also have system dependencies.
  packaged_bundle="$deb_root/opt/qingting"
  elf_args=("-e$packaged_bundle/qingting")
  while IFS= read -r -d '' library; do
    elf_args+=("-e$library")
  done < <(find "$packaged_bundle/lib" -type f -name '*.so*' -print0)
  dependencies=$(cd "$staging" && dpkg-shlibdeps --ignore-missing-info -O \
    "-l$packaged_bundle/lib" "${elf_args[@]}")
  dependencies=${dependencies#shlibs:Depends=}
  # libmpv is loaded dynamically, so ELF inspection cannot discover it.
  mpv_package=$(dpkg-query -W -f='${binary:Package}' libmpv2)
  cat > "$deb_root/DEBIAN/control" <<EOF
Package: qingting
Version: $version
Section: sound
Priority: optional
Architecture: $deb_arch
Maintainer: QingTing contributors <qingting@users.noreply.github.com>
Depends: $dependencies, $mpv_package, xdg-user-dirs
Recommends: fonts-noto-cjk
Installed-Size: $(du -sk "$deb_root/opt" | cut -f1)
Homepage: https://github.com/sadpotato1006/music_downloader
Description: QingTing music search, playback and download manager
 Flutter desktop music player with local library and synchronized lyrics.
EOF
  dpkg-deb --root-owner-group --build "$deb_root" "$project_dir/dist/$package_name.deb"
fi
