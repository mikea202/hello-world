#!/usr/bin/env bash
# Builds the Mikos Server disk image with mkosi. Usage: build-image.sh [test]
set -euo pipefail
profile=${1:-}
id=mikos-server
args=(-C images --force)
if [[ "$profile" == test ]]; then
	id=mikos-server-test
	mkdir -p out/test-ssh out/test-tree/etc/mikos-test
	[[ -f out/test-ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f out/test-ssh/id_ed25519
	cp out/test-ssh/id_ed25519.pub out/test-tree/etc/mikos-test/authorized_keys
	args+=(--profile test)
fi
mkdir -p out/images
mkosi "${args[@]}" build
qemu-img convert -c -O qcow2 "out/images/$id.raw" "out/images/$id.qcow2"
if [[ "$profile" != test ]]; then
	qemu-img convert -O vhdx -o subformat=dynamic "out/images/$id.raw" "out/images/$id.vhdx"
fi
ls -lh out/images
