#!/usr/bin/env bats
# Runs against a booted test image. boot.sh exports MIKOS_SSH and MIKOS_SSH_OPTS.

s() { $MIKOS_SSH "$@"; }

@test "system reaches running state with no failed units" {
	run s systemctl is-system-running --wait
	if [ "$output" != running ]; then s systemctl --failed --no-pager; false; fi
}

@test "identifies as Mikos" {
	run s grep '^ID=' /etc/os-release
	[ "$output" = "ID=mikos" ]
}

@test "core services active" {
	for u in ssh nftables auditd chrony fail2ban apparmor; do
		s systemctl is-active --quiet "$u"
	done
}

@test "firewall default-deny is loaded" {
	run s sudo nft list chain inet mikos input
	[[ "$output" == *"policy drop"* ]]
}

@test "root SSH login refused" {
	run ssh $MIKOS_SSH_OPTS -o BatchMode=yes root@127.0.0.1 true
	[ "$status" -ne 0 ]
}

@test "SSH host keys generated on first boot" {
	booted=$(s 'echo $(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))')
	for t in ed25519 ecdsa rsa; do
		made=$(s sudo stat -c %Y /etc/ssh/ssh_host_${t}_key)
		echo "$t key mtime $made, booted $booted"
		[ "$made" -ge $((booted - 5)) ]
	done
}

@test "only intended units are enabled" {
	for u in ssh.socket systemd-sysext.service systemd-confext.service systemd-sysext.socket \
		systemd-pcrlock-make-policy.service chrony-wait.service chronyd-restricted.service; do
		run s systemctl is-enabled "$u"
		echo "$u: $output"
		[ "$output" = disabled ]
	done
	for u in ssh.service fail2ban.service nftables.service chrony.service unattended-upgrades.service \
		systemd-networkd.service systemd-resolved.service apt-daily.timer fstrim.timer; do
		run s systemctl is-enabled "$u"
		echo "$u: $output"
		[ "$output" = enabled ]
	done
}

@test "reloading the firewall keeps fail2ban's table" {
	s sudo fail2ban-client set sshd banip 192.0.2.1
	s sudo nft list table inet f2b-table
	s sudo systemctl reload nftables
	s sudo nft list table inet f2b-table
	s sudo systemctl restart nftables
	s sudo nft list table inet f2b-table
	s sudo nft list chain inet mikos input
	s sudo fail2ban-client set sshd unbanip 192.0.2.1
}

@test "kernel command line names the root partition" {
	run s cat /proc/cmdline
	[[ "$output" == *"root=PARTLABEL=root-x86-64"* ]]
	s grep -q 'root=PARTLABEL=root-x86-64' /etc/kernel/cmdline
}

@test "apt-get update is clean" {
	run s sudo apt-get update
	echo "$output"
	[ "$status" -eq 0 ]
	! grep -Eq '^(W|E):' <<<"$output"
}

@test "password authentication not offered" {
	run ssh $MIKOS_SSH_OPTS -o BatchMode=yes -o PubkeyAuthentication=no nobody@127.0.0.1 true
	[ "$status" -ne 0 ]
	[[ "$output" == *"Permission denied (publickey)"* ]]
}

@test "AppArmor is enforcing" {
	s sudo aa-status --enabled
}

@test "lean: docker not installed, recommends disabled" {
	run s command -v docker
	[ "$status" -ne 0 ]
	s apt-config dump | grep -q 'APT::Install-Recommends "false";'
}

@test "installed footprint within 1.2 GB budget (no AI packages)" {
	used=$(s df --output=used -BM / | tail -1 | tr -dc 0-9)
	echo "used: ${used}M"
	[ "$used" -le 1200 ]
}
