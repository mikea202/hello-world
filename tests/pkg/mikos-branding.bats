#!/usr/bin/env bats

setup_file() {
	apt-get update >/dev/null
	apt-get install -y --no-install-recommends /src/out/debs/mikos-base_*_all.deb /src/out/debs/mikos-branding_*_all.deb >/dev/null
}

@test "console login banner names Mikos" {
	grep -q 'Mikos' /etc/issue.d/mikos.issue
}

@test "motd script is executable and prints the release name" {
	[ -x /etc/update-motd.d/10-mikos ]
	run /etc/update-motd.d/10-mikos
	[ "$status" -eq 0 ]
	[[ "$output" == *"Mikos 1.0"* ]]
}

@test "grub distributor set to Mikos" {
	grep -q '^GRUB_DISTRIBUTOR="Mikos"' /etc/default/grub.d/50-mikos.cfg
}
