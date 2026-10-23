#!/usr/bin/env bats
# Installs mikos-base on a clean trixie container and checks the policy it ships.

setup_file() {
	apt-get update >/dev/null
	apt-get install -y --no-install-recommends /src/out/debs/mikos-base_*_all.deb >/dev/null
}

@test "apt does not install recommends or suggests" {
	run apt-config dump
	[[ "$output" == *'APT::Install-Recommends "false";'* ]]
	[[ "$output" == *'APT::Install-Suggests "false";'* ]]
}

@test "os-release identifies Mikos with Debian lineage" {
	. /etc/os-release
	[ "$ID" = mikos ]
	[ "$ID_LIKE" = debian ]
	[ "$VERSION_ID" = "1.0" ]
	[ "$VERSION_CODENAME" = trixie ]
}

@test "original os-release and nftables.conf are diverted" {
	dpkg-divert --list /usr/lib/os-release | grep -q 'by mikos-base'
	dpkg-divert --list /etc/nftables.conf | grep -q 'by mikos-base'
	[ -f /usr/lib/os-release.debian ]
}

@test "sshd refuses root and passwords" {
	ssh-keygen -A >/dev/null
	mkdir -p /run/sshd
	run sshd -T
	[ "$status" -eq 0 ]
	[[ "$output" == *"permitrootlogin no"* ]]
	[[ "$output" == *"passwordauthentication no"* ]]
	[[ "$output" == *"kbdinteractiveauthentication no"* ]]
}

@test "nftables ruleset parses and default-denies input" {
	run nft -c -f /etc/nftables.conf
	[ "$status" -eq 0 ]
	grep -q 'type filter hook input priority filter; policy drop;' /etc/nftables.conf
	grep -q 'tcp dport 22 accept' /etc/nftables.conf
}

@test "nftables reload replaces only the mikos table" {
	! grep -q 'flush ruleset' /etc/nftables.conf
	grep -q '^destroy table inet mikos' /etc/nftables.conf
}

@test "nftables has extension chains for ssh and forwarding" {
	run nft -c -f /etc/nftables.conf
	[ "$status" -eq 0 ]
	awk '/chain allow_ssh/{s=1} s && /tcp dport 22 accept/{print "ok"; exit}' /etc/nftables.conf | grep -q ok
	grep -q 'jump allow_ssh' /etc/nftables.conf
	grep -q 'chain forward_extra' /etc/nftables.conf
	grep -q 'jump forward_extra' /etc/nftables.conf
}

@test "nftables service stop removes only the mikos table" {
	f=/usr/lib/systemd/system/nftables.service.d/50-mikos.conf
	grep -qx 'ExecStop=' "$f"
	grep -qx 'ExecStop=/usr/sbin/nft destroy table inet mikos' "$f"
}

@test "sysctl hardening drop-in present" {
	grep -q '^kernel.kptr_restrict = 2' /etc/sysctl.d/50-mikos.conf
	grep -q '^net.ipv4.conf.all.rp_filter = 1' /etc/sysctl.d/50-mikos.conf
	for k in 'net.ipv4.conf.default.send_redirects = 0' \
		'net.ipv4.conf.default.accept_source_route = 0' \
		'net.ipv6.conf.all.accept_source_route = 0' \
		'kernel.yama.ptrace_scope = 1'; do
		grep -qx "$k" /etc/sysctl.d/50-mikos.conf
	done
}

@test "unattended-upgrades limited to Debian security and Mikos" {
	run apt-config dump Unattended-Upgrade::Origins-Pattern
	[[ "$output" == *"origin=Mikos"* ]]
	[[ "$output" == *"Debian-Security"* ]]
	[[ "$output" != *'label=Debian";'* ]]
	apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade "1";'
}

@test "Mikos APT source and keyring installed" {
	grep -q '^URIs: https://mikea202.github.io/mikos/apt' /etc/apt/sources.list.d/mikos.sources
	[ -s /usr/share/keyrings/mikos-archive-keyring.gpg ]
}

@test "systemd preset enables the hardened services and not ssh.socket" {
	f=/usr/lib/systemd/system-preset/50-mikos.preset
	for u in ssh.service sshd-keygen.service nftables.service auditd.service audit-rules.service \
		chrony.service apparmor.service unattended-upgrades.service \
		apt-daily.timer apt-daily-upgrade.timer fstrim.timer; do
		grep -qx "enable $u" "$f"
	done
	grep -qx 'disable ssh.socket' "$f"
}

@test "auditd rules watch identity and firewall files" {
	grep -q -- '-k mikos-identity' /etc/audit/rules.d/50-mikos.rules
	grep -q -- '-k mikos-firewall' /etc/audit/rules.d/50-mikos.rules
}

@test "core dependencies installed" {
	for p in apparmor auditd chrony nftables openssh-server unattended-upgrades; do
		dpkg -s "$p" | grep -q 'Status: install ok installed'
	done
}

@test "dpkg drops docs and translations for newly installed packages" {
	apt-get install -y hello >/dev/null
	[ "$(ls /usr/share/doc/hello)" = copyright ]
	[ ! -e /usr/share/locale/de/LC_MESSAGES/hello.mo ]
	[ -e /usr/share/man/man1/hello.1.gz ]
}

@test "reinstall is non-interactive and keeps local firewall edits" {
	echo '# local edit' >>/etc/nftables.conf
	apt-get install -y --reinstall /src/out/debs/mikos-base_*_all.deb </dev/null >/dev/null
	grep -qx '# local edit' /etc/nftables.conf
	sed -i '/^# local edit$/d' /etc/nftables.conf
}

@test "removing mikos-base restores diverted files" {
	apt-get remove -y mikos-base >/dev/null
	! dpkg-divert --list /usr/lib/os-release | grep -q mikos-base
	. /usr/lib/os-release
	[ "$ID" = debian ]
	[ ! -e /etc/nftables.conf.debian ]
	grep -q 'table inet filter' /etc/nftables.conf
}
