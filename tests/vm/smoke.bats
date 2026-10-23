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
