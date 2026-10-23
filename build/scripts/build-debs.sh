#!/usr/bin/env bash
# Builds every package under packages/ into out/debs.
set -euo pipefail
rm -rf out/debs out/pkgbuild
mkdir -p out/debs out/pkgbuild
build/scripts/gen-dev-key.sh
install -D -m644 out/mikos-archive-keyring.gpg packages/mikos-base/keyring/mikos-archive-keyring.gpg
for pkg in packages/*/; do
	name=$(basename "$pkg")
	cp -a "$pkg" "out/pkgbuild/$name"
	(cd "out/pkgbuild/$name" && dpkg-buildpackage -b -us -uc -rfakeroot)
done
mv out/pkgbuild/*.deb out/debs/
rm -rf out/pkgbuild
ls -l out/debs
