#!/usr/bin/env bats

setup_file() {
	install -m644 /src/out/repo/apt/mikos-archive-keyring.gpg /usr/share/keyrings/mikos-test.gpg
	echo "deb [signed-by=/usr/share/keyrings/mikos-test.gpg] file:/src/out/repo/apt trixie main" \
		>/etc/apt/sources.list.d/mikos-test.list
}

@test "Release file has Mikos origin" {
	grep -q '^Origin: Mikos' /src/out/repo/apt/dists/trixie/Release
	grep -q '^Suite: trixie' /src/out/repo/apt/dists/trixie/Release
}

@test "apt accepts the signed repo" {
	run apt-get update
	[ "$status" -eq 0 ]
	[[ "$output" != *"NO_PUBKEY"* ]]
	[[ "$output" != *"is not signed"* ]]
}

@test "mikos-server installs from the repo" {
	apt-get update >/dev/null
	run apt-get install -y --no-install-recommends mikos-server
	[ "$status" -eq 0 ]
	[ "$(apt-cache policy mikos-server | awk '/Installed:/ {print $2}')" = 1.0.0 ]
}
