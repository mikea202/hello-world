#!/usr/bin/env bash
# Fails if any built artifact exceeds its budget from the spec (§2a).
set -euo pipefail
shopt -s nullglob
fail=0
check() { # file max_mb
	local mb=$(( $(stat -c %s "$1") / 1024 / 1024 ))
	if (( mb > $2 )); then echo "OVER  $1: ${mb}M > $2M"; fail=1; else echo "ok    $1: ${mb}M <= $2M"; fi
}
check out/images/mikos-server.qcow2 1024
for iso in out/iso/mikos-server-*.iso; do check "$iso" 900; done
exit $fail
