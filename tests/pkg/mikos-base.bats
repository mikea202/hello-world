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

@test "sysctl hardening drop-in present" {
	grep -q '^kernel.kptr_restrict = 2' /etc/sysctl.d/50-mikos.conf
	grep -q '^net.ipv4.conf.all.rp_filter = 1' /etc/sysctl.d/50-mikos.conf
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

@test "removing mikos-base restores diverted files" {
	apt-get remove -y mikos-base >/dev/null
	! dpkg-divert --list /usr/lib/os-release | grep -q mikos-base
	. /usr/lib/os-release
	[ "$ID" = debian ]
}
