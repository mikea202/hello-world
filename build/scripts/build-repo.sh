#!/usr/bin/env bash
# Publishes out/debs as a signed APT repo at out/repo/apt (suite trixie, component main).
set -euo pipefail
export GNUPGHOME=$PWD/out/gnupg
keyid=$(cat out/keyid)
root=$PWD/out/aptly
rm -rf "$root" out/repo
printf '{"rootDir": "%s", "gpgProvider": "gpg"}\n' "$root" >out/aptly.conf
aptly() { command aptly -config=out/aptly.conf "$@"; }
aptly repo create -distribution=trixie -component=main mikos
aptly repo add mikos out/debs/
aptly publish repo -batch -gpg-key="$keyid" -origin=Mikos -label=Mikos -architectures=amd64 mikos
mkdir -p out/repo/apt
cp -a "$root/public/." out/repo/apt/
cp out/mikos-archive-keyring.gpg out/repo/apt/
