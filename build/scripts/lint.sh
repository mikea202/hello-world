#!/usr/bin/env bash
# Runs shellcheck on every shell script we ship or run; lintian errors fail the build.
set -euo pipefail
shopt -s nullglob
scripts=(build/scripts/*.sh tests/vm/*.sh packages/*/debian/{preinst,postinst,postrm} packages/*/files/etc/update-motd.d/* images/mkosi.finalize images/*.chroot)
shellcheck "${scripts[@]}"
lintian --fail-on error --no-tag-display-limit out/debs/*.deb
