#!/usr/bin/env bash
# Static checks on a built disk image (no boot needed). Usage: check-image.sh IMAGE.raw
set -euo pipefail
img=$1
fail=0
bad() { echo "FAIL  $*"; fail=1; }
ok() { echo "ok    $*"; }

# Partition start offsets (bytes) by GPT partition name.
part_off() { sfdisk -d "$img" | awk -v n="name=\"$1\"" 'index($0, n) { sub(/.*start= */, ""); sub(/,.*/, ""); print $0 * 512 }'; }
root_off=$(part_off root-x86-64)
esp_off=$(part_off esp)
[[ -n "$root_off" && -n "$esp_off" ]] || { echo "FAIL  partitions root-x86-64/esp not found in $img"; exit 1; }

rootfs() { debugfs -R "$1" "$img?offset=$root_off" 2>/dev/null; }

if keys=$(rootfs "ls /etc/ssh" | tr -s ' ' '\n' | grep '^ssh_host_'); then
	bad "SSH host keys baked into image: $(echo "$keys" | tr '\n' ' ')"
else
	ok "no SSH host keys in image"
fi

cmdline=$(rootfs "cat /etc/kernel/cmdline")
if [[ "$cmdline" == *root=PARTLABEL=root-x86-64* ]]; then ok "/etc/kernel/cmdline has root="; else bad "/etc/kernel/cmdline lacks root= ($cmdline)"; fi

entries=$(mdir -b -i "$img@@$esp_off" ::/loader/entries 2>/dev/null || true)
[[ -n "$entries" ]] || bad "no boot loader entries on ESP"
for e in $entries; do
	opts=$(mtype -i "$img@@$esp_off" "$e" | sed -n 's/^options //p')
	if [[ "$opts" == *root=PARTLABEL=root-x86-64* ]] && (( $(grep -o 'root=' <<<"$opts" | wc -l) == 1 )); then
		ok "boot entry ${e##*/} has root="
	else
		bad "boot entry ${e##*/} needs exactly one root=PARTLABEL=root-x86-64: $opts"
	fi
done

if rootfs "ls /etc/systemd/system/sockets.target.wants" | grep -q 'ssh\.socket'; then
	bad "ssh.socket enabled"
else
	ok "ssh.socket not enabled"
fi

exit $fail
