#!/usr/bin/env bats

setup_file() {
	apt-get update >/dev/null
	apt-get install -y --no-install-recommends /src/out/debs/mikos-*_all.deb >/dev/null
}

@test "mikos-server pulls base and branding" {
	for p in mikos-base mikos-branding mikos-server fail2ban; do
		dpkg -s "$p" | grep -q 'Status: install ok installed'
	done
}

@test "fail2ban config is valid and sshd jail enabled with nftables" {
	run fail2ban-client --test
	[ "$status" -eq 0 ]
	grep -q '^banaction = nftables-multiport' /etc/fail2ban/jail.d/50-mikos.conf
	run awk '/^\[sshd\]/{s=1} s && /^enabled = true/{print "ok"; exit}' /etc/fail2ban/jail.d/50-mikos.conf
	[ "$output" = ok ]
}

@test "lean: no docker, cockpit or powershell" {
	! dpkg -l | awk '{print $2}' | grep -Eq '^(docker|cockpit|powershell)'
}
