#!/usr/bin/env bash
# Boots the test image in QEMU (UEFI), waits for SSH, runs every tests/vm/*.bats suite.
set -euo pipefail
img=out/images/mikos-server-test.qcow2
key=out/test-ssh/id_ed25519
work=$(mktemp -d)
trap 'kill "$(cat "$work/qemu.pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$work"' EXIT
cp "$img" "$work/disk.qcow2"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$work/vars.fd"
chmod 600 "$key"
accel=tcg
[[ -w /dev/kvm ]] && accel=kvm

qemu-system-x86_64 -machine q35,accel=$accel -m 2048 -smp 2 -display none \
	-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
	-drive if=pflash,format=raw,file="$work/vars.fd" \
	-drive file="$work/disk.qcow2",if=virtio \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
	-serial file:"$work/serial.log" -daemonize -pidfile "$work/qemu.pid"

export MIKOS_SSH_OPTS="-i $key -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
export MIKOS_SSH="ssh $MIKOS_SSH_OPTS mikos@127.0.0.1"

for _ in $(seq 1 120); do
	$MIKOS_SSH true 2>/dev/null && break
	sleep 2
done
if ! $MIKOS_SSH true; then
	echo "SSH never came up; last serial output:"
	tail -n 60 "$work/serial.log"
	exit 1
fi
bats tests/vm/*.bats
