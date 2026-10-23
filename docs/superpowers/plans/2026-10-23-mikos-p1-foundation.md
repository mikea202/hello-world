# Mikos P1 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `mikos-base`, `mikos-branding` and `mikos-server` as signed Debian packages in a local APT repo, produce a bootable Mikos Server qcow2/vhdx image, and prove it with package, repo and QEMU boot tests in CI.

**Architecture:** A host `Makefile` drives everything through two Docker images: `mikos-build` (packaging, aptly, mkosi, QEMU) and `mikos-test` (clean Debian 13 plus bats, for install tests). Packages are native debhelper packages under `packages/`. All customization lives in drop-in config files, and `dpkg-divert` is used where another package's file must be replaced. mkosi builds a UEFI disk image from Debian plus the local debs. A `test` profile adds an SSH test user so `tests/vm/boot.sh` can boot the image in QEMU and run bats smoke tests over SSH.

**Tech Stack:** Debian 13 (trixie), debhelper 13, aptly, GnuPG, mkosi, systemd-boot, QEMU + OVMF, bats, shellcheck, lintian, GitHub Actions.

Spec: `docs/superpowers/specs/2026-10-23-mikos-server-design.md`. Roadmap: `docs/superpowers/plans/2026-10-23-mikos-roadmap.md`.

## Global Constraints

- Base: Debian 13 (trixie), amd64 only.
- Package names `mikos-*`, version `1.0.0`, source format `3.0 (native)`, `debhelper-compat (= 13)`, `Architecture: all`.
- Ship config as drop-ins (`*.d/`). Replace another package's file only via `dpkg-divert` in preinst, and undo it in postrm.
- `APT::Install-Recommends "false"` and `APT::Install-Suggests "false"` set in mikos-base, the installer and the image builds.
- dpkg `path-exclude`: drop `/usr/share/doc/*` (keep copyright), non-English locales, translated man pages. English man pages stay.
- APT repo: URL `https://mikea202.github.io/mikos/apt`, suite `trixie`, component `main`, `Origin: Mikos`, keyring `/usr/share/keyrings/mikos-archive-keyring.gpg`.
- `os-release`: `ID=mikos`, `ID_LIKE=debian`, `VERSION_ID=1.0`, `VERSION_CODENAME=trixie`.
- sshd: no root login, key-only auth.
- nftables: default-deny inbound, allow established + SSH.
- unattended-upgrades: Debian security + Mikos repo only.
- mikos-server does **not** include Docker or Cockpit.
- Size budgets: server ISO ≤ 900 MB; server installed ≤ 1.2 GB without AI packages; qcow2 ≤ 1.0 GB compressed.
- No network fetches at package install time.
- Host needs only `docker` + `make` (Windows 11: run from WSL2).

---

## File Structure

```
.gitignore
Makefile                              # host entry point; all steps run in containers
build/Dockerfile                      # mikos-build image
build/Dockerfile.test                 # mikos-test image (clean trixie + bats)
build/scripts/gen-dev-key.sh          # create/import repo signing key, export public keyring
build/scripts/build-debs.sh           # build every packages/* into out/debs
build/scripts/lint.sh                 # shellcheck + lintian
build/scripts/build-repo.sh           # aptly signed repo → out/repo/apt
build/scripts/build-image.sh          # mkosi → raw → qcow2/vhdx
build/scripts/check-size.sh           # artifact size budgets
packages/mikos-base/debian/{control,rules,changelog,copyright,install,preinst,postinst,postrm,source/format}
packages/mikos-base/files/...         # config payload
packages/mikos-branding/debian/{control,rules,changelog,copyright,install,source/format}
packages/mikos-branding/files/...
packages/mikos-server/debian/{control,rules,changelog,copyright,install,source/format}
packages/mikos-server/files/...
images/mkosi.conf                     # Mikos Server image
images/mkosi.extra/...                # image-only files (DHCP networking)
images/mkosi.conf.d/20-test.conf      # test profile
images/mkosi.test-postinst.chroot     # creates SSH test user
tests/pkg/mikos-base.bats
tests/pkg/mikos-branding.bats
tests/pkg/mikos-server.bats
tests/repo/repo.bats
tests/vm/boot.sh
tests/vm/smoke.bats
.github/workflows/ci.yml
```

---

### Task 1: Build environment scaffold

**Files:**
- Create: `.gitignore`, `Makefile`, `build/Dockerfile`, `build/Dockerfile.test`
- Modify: `README.md`

**Interfaces:**
- Produces: docker images `mikos-build:latest` and `mikos-test:latest`, and Make targets `build-image test-image shell debs lint test-pkg repo test-repo image test-vm size clean`. Later tasks add the scripts these targets call: `build/scripts/{build-debs,lint,build-repo,build-image,check-size}.sh` and `tests/vm/boot.sh`. Every build script runs with cwd `/src` = repo root.

- [ ] **Step 1: Write `.gitignore`**

```
out/
packages/mikos-base/keyring/
```

- [ ] **Step 2: Write `build/Dockerfile`**

```dockerfile
FROM debian:trixie
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential debhelper devscripts fakeroot lintian shellcheck bats \
        aptly gnupg ca-certificates curl \
        mkosi apt debian-archive-keyring systemd-container systemd-repart \
        systemd-boot systemd-boot-efi systemd-ukify dosfstools mtools e2fsprogs zstd cpio \
        qemu-system-x86 qemu-utils ovmf openssh-client \
    && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 3: Write `build/Dockerfile.test`**

```dockerfile
FROM debian:trixie
ARG DEBIAN_FRONTEND=noninteractive
# policy-rc.d stops maintainer scripts from starting daemons inside the container.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d \
    && apt-get update && apt-get install -y --no-install-recommends bats ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ENV DEBIAN_FRONTEND=noninteractive
```

- [ ] **Step 4: Write `Makefile`**

```make
# Mikos build entry point. Everything runs in containers; the host needs only docker + make.
SHELL     := /bin/bash
BUILD_IMG := mikos-build:latest
TEST_IMG  := mikos-test:latest
KVM       := $(if $(wildcard /dev/kvm),--device /dev/kvm,)
RUN       := docker run --rm -v $(CURDIR):/src -w /src -e MIKOS_GPG_KEY $(BUILD_IMG)
RUN_PRIV  := docker run --rm --privileged -v $(CURDIR):/src -w /src $(BUILD_IMG)
RUN_TEST  := docker run --rm --cap-add NET_ADMIN -v $(CURDIR):/src -w /src $(TEST_IMG)
PROFILE   ?=

.PHONY: build-image test-image shell debs lint test-pkg repo test-repo image test-vm size clean

build-image:
	docker build -t $(BUILD_IMG) -f build/Dockerfile build

test-image:
	docker build -t $(TEST_IMG) -f build/Dockerfile.test build

shell: build-image
	docker run --rm -it --privileged -v $(CURDIR):/src -w /src $(BUILD_IMG) bash

debs: build-image
	$(RUN) build/scripts/build-debs.sh

lint: build-image
	$(RUN) build/scripts/lint.sh

# Each suite runs in a fresh container so packages are tested on a clean Debian.
test-pkg: test-image
	@for t in tests/pkg/*.bats; do echo "== $$t"; $(RUN_TEST) bats $$t || exit 1; done

repo: build-image
	$(RUN) build/scripts/build-repo.sh

test-repo: test-image
	$(RUN_TEST) bats tests/repo/repo.bats

image: build-image
	$(RUN_PRIV) build/scripts/build-image.sh $(PROFILE)

test-vm: build-image
	docker run --rm $(KVM) -v $(CURDIR):/src -w /src $(BUILD_IMG) tests/vm/boot.sh

size: build-image
	$(RUN) build/scripts/check-size.sh

clean:
	docker run --rm -v $(CURDIR):/src -w /src debian:trixie rm -rf out packages/mikos-base/keyring
```

- [ ] **Step 5: Verify the build image has every tool**

Run:
```bash
make build-image test-image
docker run --rm mikos-build:latest sh -c 'dpkg-buildpackage --version | head -1 && mkosi --version && aptly version && bats --version && qemu-system-x86_64 --version | head -1 && ls /usr/share/OVMF/OVMF_CODE_4M.fd'
docker run --rm mikos-test:latest bats --version
```
Expected: each command prints a version line, the OVMF path is printed, and the exit code is 0. If an apt package name is wrong, `docker build` fails and names it. Fix the name in the Dockerfile before going on.

- [ ] **Step 6: Add a build section to `README.md`**

Replace the file contents with:

```markdown
# Mikos

Debian 13 based server distro with a governed AI harness. Spec: `docs/superpowers/specs/2026-10-23-mikos-server-design.md`.

## Build

Requires docker and make (Windows 11: use WSL2).

    make debs lint test-pkg      # build + test packages
    make repo test-repo          # signed local APT repo
    make image PROFILE=test      # test VM image
    make test-vm                 # boot it in QEMU and run smoke tests
    make image size              # release image + size budgets
```

- [ ] **Step 7: Commit**

```bash
git add .gitignore Makefile build/Dockerfile build/Dockerfile.test README.md
git commit -m "build: add containerized build environment and Makefile"
```

---

### Task 2: mikos-base package

**Files:**
- Create: `build/scripts/gen-dev-key.sh`, `build/scripts/build-debs.sh`
- Create: `packages/mikos-base/debian/{control,rules,changelog,copyright,install,preinst,postinst,postrm,source/format}`
- Create: `packages/mikos-base/files/etc/apt/apt.conf.d/00mikos-norecommends`
- Create: `packages/mikos-base/files/etc/apt/apt.conf.d/21mikos-auto-upgrades`
- Create: `packages/mikos-base/files/etc/apt/apt.conf.d/52mikos-unattended-upgrades`
- Create: `packages/mikos-base/files/etc/apt/sources.list.d/mikos.sources`
- Create: `packages/mikos-base/files/etc/dpkg/dpkg.cfg.d/01mikos-lean`
- Create: `packages/mikos-base/files/etc/ssh/sshd_config.d/50-mikos.conf`
- Create: `packages/mikos-base/files/etc/sysctl.d/50-mikos.conf`
- Create: `packages/mikos-base/files/etc/nftables.conf`
- Create: `packages/mikos-base/files/etc/nftables.d/00-mikos.nft`
- Create: `packages/mikos-base/files/etc/audit/rules.d/50-mikos.rules`
- Create: `packages/mikos-base/files/usr/lib/os-release`
- Create: `packages/mikos-base/files/usr/lib/systemd/system-preset/50-mikos.preset`
- Test: `tests/pkg/mikos-base.bats`

**Interfaces:**
- Consumes: `make debs`, `make test-pkg` (Task 1).
- Produces:
  - `out/debs/mikos-base_1.0.0_all.deb`
  - `out/gnupg/` (GNUPGHOME holding the signing key)
  - `out/keyid` (signing key fingerprint)
  - `out/mikos-archive-keyring.gpg` (public keyring)
  - nftables table `inet mikos` with chains `input` (policy drop), `input_extra` (empty, for drop-ins to add rules to), `forward` (policy drop) and `output`. Drop-ins go in `/etc/nftables.d/*.nft`.

- [ ] **Step 1: Write the failing test `tests/pkg/mikos-base.bats`**

```bash
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
```

- [ ] **Step 2: Write `build/scripts/gen-dev-key.sh`**

```bash
#!/usr/bin/env bash
# Creates (dev) or imports (CI: $MIKOS_GPG_KEY) the repo signing key into out/gnupg
# and exports the public keyring that mikos-base ships.
set -euo pipefail
export GNUPGHOME=$PWD/out/gnupg
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
if [[ -n "${MIKOS_GPG_KEY:-}" ]]; then
	gpg --batch --import <<<"$MIKOS_GPG_KEY"
elif ! gpg --batch --list-secret-keys 'Mikos' >/dev/null 2>&1; then
	gpg --batch --passphrase '' --quick-gen-key 'Mikos Dev Archive <dev@mikos.invalid>' ed25519 sign 1y
fi
keyid=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
gpg --batch --export "$keyid" >out/mikos-archive-keyring.gpg
echo "$keyid" >out/keyid
```

- [ ] **Step 3: Write `build/scripts/build-debs.sh`**

```bash
#!/usr/bin/env bash
# Builds every package under packages/ into out/debs.
set -euo pipefail
rm -rf out/debs out/pkgbuild
mkdir -p out/debs out/pkgbuild
build/scripts/gen-dev-key.sh
install -D -m644 out/mikos-archive-keyring.gpg packages/mikos-base/keyring/mikos-archive-keyring.gpg
for pkg in packages/*/; do
	name=$(basename "$pkg")
	cp -a "$pkg" "out/pkgbuild/$name"
	(cd "out/pkgbuild/$name" && dpkg-buildpackage -b -us -uc -rfakeroot)
done
mv out/pkgbuild/*.deb out/debs/
rm -rf out/pkgbuild
ls -l out/debs
```

Then run: `chmod +x build/scripts/*.sh`

- [ ] **Step 4: Run the test to verify it fails**

Run: `make test-pkg`
Expected: FAIL. `setup_file` errors because `/src/out/debs/mikos-base_*_all.deb` does not exist.

- [ ] **Step 5: Write the debian packaging files**

`packages/mikos-base/debian/source/format`:
```
3.0 (native)
```

`packages/mikos-base/debian/control`:
```
Source: mikos-base
Section: admin
Priority: optional
Maintainer: Mikos Maintainers <maint@mikos.invalid>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.7.0
Rules-Requires-Root: no

Package: mikos-base
Architecture: all
Depends: ${misc:Depends},
 apparmor,
 auditd,
 ca-certificates,
 chrony,
 curl,
 git,
 htop,
 jq,
 nftables,
 openssh-server,
 tmux,
 unattended-upgrades,
 vim-tiny
Description: Mikos base system configuration
 Hardening, APT policy, repository and defaults shared by all Mikos variants.
```

`packages/mikos-base/debian/rules` (then `chmod +x`):
```make
#!/usr/bin/make -f
%:
	dh $@
```

`packages/mikos-base/debian/changelog`:
```
mikos-base (1.0.0) trixie; urgency=medium

  * Initial release.

 -- Mikos Maintainers <maint@mikos.invalid>  Fri, 23 Oct 2026 00:00:00 +0000
```

`packages/mikos-base/debian/copyright`:
```
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: mikos

Files: *
Copyright: 2026 Mikos Maintainers
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files, to deal in the software
 without restriction, subject to including this notice in all copies.
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
```

`packages/mikos-base/debian/install`:
```
files/etc/* etc/
files/usr/* usr/
keyring/mikos-archive-keyring.gpg usr/share/keyrings/
```

`packages/mikos-base/debian/preinst`:
```sh
#!/bin/sh
set -e
if [ "$1" = install ] || [ "$1" = upgrade ]; then
	for f in /usr/lib/os-release /etc/nftables.conf; do
		dpkg-divert --package mikos-base --add --rename --divert "$f.debian" "$f"
	done
fi
#DEBHELPER#
```

`packages/mikos-base/debian/postinst`:
```sh
#!/bin/sh
set -e
if [ "$1" = configure ] && command -v systemctl >/dev/null 2>&1; then
	systemctl enable nftables.service >/dev/null 2>&1 || true
	if [ -d /run/systemd/system ]; then
		sysctl --system >/dev/null || true
		systemctl restart nftables.service || true
		systemctl reload ssh.service 2>/dev/null || true
	fi
fi
#DEBHELPER#
```

`packages/mikos-base/debian/postrm`:
```sh
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = abort-install ] || [ "$1" = disappear ]; then
	# Our nftables.conf is a conffile and survives remove; drop it so the Debian one can return.
	rm -f /etc/nftables.conf
	for f in /usr/lib/os-release /etc/nftables.conf; do
		dpkg-divert --package mikos-base --remove --rename --divert "$f.debian" "$f"
	done
fi
#DEBHELPER#
```

- [ ] **Step 6: Write the config payload**

`files/etc/apt/apt.conf.d/00mikos-norecommends`:
```
APT::Install-Recommends "false";
APT::Install-Suggests "false";
```

`files/etc/apt/apt.conf.d/21mikos-auto-upgrades`:
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```

`files/etc/apt/apt.conf.d/52mikos-unattended-upgrades`:
```
// Mikos: security updates from Debian plus the Mikos repo only.
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
	"origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
	"origin=Mikos,codename=${distro_codename}";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
```

`files/etc/apt/sources.list.d/mikos.sources`:
```
Types: deb
URIs: https://mikea202.github.io/mikos/apt
Suites: trixie
Components: main
Signed-By: /usr/share/keyrings/mikos-archive-keyring.gpg
```

`files/etc/dpkg/dpkg.cfg.d/01mikos-lean`:
```
# Mikos lean policy: no docs, translations or info pages. English man pages stay.
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/??/*
path-exclude /usr/share/man/??_*/*
path-exclude /usr/share/man/??.*/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/en*
path-include /usr/share/locale/locale.alias
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
```

`files/etc/ssh/sshd_config.d/50-mikos.conf`:
```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
```

`files/etc/sysctl.d/50-mikos.conf`:
```
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
```

`files/etc/nftables.conf`:
```
#!/usr/sbin/nft -f
# Mikos base firewall. Add rules from /etc/nftables.d/*.nft, e.g.
#   add rule inet mikos input_extra tcp dport 443 accept
flush ruleset

table inet mikos {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
		ct state invalid drop
		iif "lo" accept
		meta l4proto { icmp, ipv6-icmp } accept
		tcp dport 22 accept
		jump input_extra
	}

	chain input_extra {
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}

include "/etc/nftables.d/*.nft"
```

`files/etc/nftables.d/00-mikos.nft`:
```
# Placeholder so the include glob always matches. Put local rules in other *.nft files.
```

`files/etc/audit/rules.d/50-mikos.rules`:
```
-w /etc/sudoers -p wa -k mikos-identity
-w /etc/sudoers.d/ -p wa -k mikos-identity
-w /etc/passwd -p wa -k mikos-identity
-w /etc/shadow -p wa -k mikos-identity
-w /etc/group -p wa -k mikos-identity
-w /etc/ssh/sshd_config -p wa -k mikos-sshd
-w /etc/ssh/sshd_config.d/ -p wa -k mikos-sshd
-w /etc/nftables.conf -p wa -k mikos-firewall
-w /etc/nftables.d/ -p wa -k mikos-firewall
```

`files/usr/lib/os-release`:
```
PRETTY_NAME="Mikos 1.0"
NAME="Mikos"
VERSION_ID="1.0"
VERSION="1.0"
VERSION_CODENAME=trixie
ID=mikos
ID_LIKE=debian
HOME_URL="https://github.com/mikea202/mikos"
SUPPORT_URL="https://github.com/mikea202/mikos/issues"
BUG_REPORT_URL="https://github.com/mikea202/mikos/issues"
```

`files/usr/lib/systemd/system-preset/50-mikos.preset`:
```
enable nftables.service
enable auditd.service
enable chrony.service
enable ssh.service
enable apparmor.service
```

- [ ] **Step 7: Build and run the test to verify it passes**

Run: `make debs test-pkg`
Expected: `out/debs/mikos-base_1.0.0_all.deb` is listed, and bats reports `12 tests, 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add build/scripts/gen-dev-key.sh build/scripts/build-debs.sh packages/mikos-base tests/pkg/mikos-base.bats
git commit -m "feat(mikos-base): hardening, lean APT/dpkg policy, repo source, os-release"
```

---

### Task 3: mikos-branding package

**Files:**
- Create: `packages/mikos-branding/debian/{control,rules,changelog,copyright,install,source/format}`
- Create: `packages/mikos-branding/files/etc/issue.d/mikos.issue`
- Create: `packages/mikos-branding/files/etc/update-motd.d/10-mikos`
- Create: `packages/mikos-branding/files/etc/default/grub.d/50-mikos.cfg`
- Test: `tests/pkg/mikos-branding.bats`

**Interfaces:**
- Consumes: `/etc/os-release` from mikos-base (Task 2). The motd script reads `PRETTY_NAME`.
- Produces: `out/debs/mikos-branding_1.0.0_all.deb`.

- [ ] **Step 1: Write the failing test `tests/pkg/mikos-branding.bats`**

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make debs test-pkg`
Expected: `mikos-base.bats` passes, then `mikos-branding.bats` fails in `setup_file` because there's no `mikos-branding_*_all.deb`.

- [ ] **Step 3: Write the packaging files**

`packages/mikos-branding/debian/source/format`:
```
3.0 (native)
```

`packages/mikos-branding/debian/control`:
```
Source: mikos-branding
Section: misc
Priority: optional
Maintainer: Mikos Maintainers <maint@mikos.invalid>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.7.0
Rules-Requires-Root: no

Package: mikos-branding
Architecture: all
Depends: ${misc:Depends}, mikos-base (>= 1.0.0)
Description: Mikos branding (minimal)
 Console banner, login message and boot menu name for Mikos.
```

`packages/mikos-branding/debian/rules` (then `chmod +x`):
```make
#!/usr/bin/make -f
%:
	dh $@
```

`packages/mikos-branding/debian/changelog`:
```
mikos-branding (1.0.0) trixie; urgency=medium

  * Initial release.

 -- Mikos Maintainers <maint@mikos.invalid>  Fri, 23 Oct 2026 00:00:00 +0000
```

`packages/mikos-branding/debian/copyright`:
```
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: mikos

Files: *
Copyright: 2026 Mikos Maintainers
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files, to deal in the software
 without restriction, subject to including this notice in all copies.
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
```

`packages/mikos-branding/debian/install`:
```
files/etc/* etc/
```

- [ ] **Step 4: Write the payload**

`files/etc/issue.d/mikos.issue`:
```
Mikos 1.0 \n (\l)

```

`files/etc/update-motd.d/10-mikos` (then `chmod +x`):
```sh
#!/bin/sh
. /etc/os-release
printf '\n  %s on %s\n\n' "$PRETTY_NAME" "$(hostname)"
```

`files/etc/default/grub.d/50-mikos.cfg`:
```
GRUB_DISTRIBUTOR="Mikos"
```

- [ ] **Step 5: Build and run the tests to verify they pass**

Run: `make debs test-pkg`
Expected: both suites pass (`3 tests, 0 failures` for branding).

- [ ] **Step 6: Commit**

```bash
git add packages/mikos-branding tests/pkg/mikos-branding.bats
git commit -m "feat(mikos-branding): console banner, motd, grub distributor"
```

---

### Task 4: mikos-server package

**Files:**
- Create: `packages/mikos-server/debian/{control,rules,changelog,copyright,install,source/format}`
- Create: `packages/mikos-server/files/etc/fail2ban/jail.d/50-mikos.conf`
- Test: `tests/pkg/mikos-server.bats`

**Interfaces:**
- Consumes: mikos-base (Task 2), mikos-branding (Task 3).
- Produces: `out/debs/mikos-server_1.0.0_all.deb`, the meta-package installed by images (Task 7).

- [ ] **Step 1: Write the failing test `tests/pkg/mikos-server.bats`**

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make debs test-pkg`
Expected: `mikos-server.bats` fails. The first test errors because `mikos-server` isn't installed.

- [ ] **Step 3: Write the packaging files**

`packages/mikos-server/debian/source/format`:
```
3.0 (native)
```

`packages/mikos-server/debian/control`:
```
Source: mikos-server
Section: metapackages
Priority: optional
Maintainer: Mikos Maintainers <maint@mikos.invalid>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.7.0
Rules-Requires-Root: no

Package: mikos-server
Architecture: all
Depends: ${misc:Depends},
 mikos-base (>= 1.0.0),
 mikos-branding (>= 1.0.0),
 fail2ban,
 python3-systemd
Description: Mikos Server meta-package
 Lean headless server. Docker, Cockpit and PowerShell are optional
 packages (mikos-docker, mikos-cockpit, mikos-pwsh).
```

`packages/mikos-server/debian/rules` (then `chmod +x`):
```make
#!/usr/bin/make -f
%:
	dh $@
```

`packages/mikos-server/debian/changelog`:
```
mikos-server (1.0.0) trixie; urgency=medium

  * Initial release.

 -- Mikos Maintainers <maint@mikos.invalid>  Fri, 23 Oct 2026 00:00:00 +0000
```

`packages/mikos-server/debian/copyright`:
```
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: mikos

Files: *
Copyright: 2026 Mikos Maintainers
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files, to deal in the software
 without restriction, subject to including this notice in all copies.
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
```

`packages/mikos-server/debian/install`:
```
files/etc/* etc/
```

`files/etc/fail2ban/jail.d/50-mikos.conf`:
```
[DEFAULT]
backend = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
```

- [ ] **Step 4: Build and run the tests to verify they pass**

Run: `make debs test-pkg`
Expected: all three suites pass. If `fail2ban-client --test` fails only because the container has no systemd journal, run `docker run --rm -it -v $PWD:/src mikos-test:latest bash`, reproduce it, and read the error. Fix the config if the error is in the config. Leave the test as it is.

- [ ] **Step 5: Commit**

```bash
git add packages/mikos-server tests/pkg/mikos-server.bats
git commit -m "feat(mikos-server): lean server meta-package with fail2ban"
```

---

### Task 5: Lint gate

**Files:**
- Create: `build/scripts/lint.sh`

**Interfaces:**
- Consumes: `out/debs/*.deb` (Tasks 2–4).
- Produces: `make lint`, which exits non-zero on any shellcheck finding or lintian error.

- [ ] **Step 1: Write `build/scripts/lint.sh`** (then `chmod +x`)

```bash
#!/usr/bin/env bash
# shellcheck on every shell script we ship or run; lintian errors fail the build.
set -euo pipefail
shopt -s nullglob
scripts=(build/scripts/*.sh tests/vm/*.sh packages/*/debian/{preinst,postinst,postrm} packages/*/files/etc/update-motd.d/*)
shellcheck "${scripts[@]}"
lintian --fail-on error --no-tag-display-limit out/debs/*.deb
```

- [ ] **Step 2: Run it**

Run: `make lint`
Expected: exit 0. Warnings are allowed, errors are not. Fix any error in the package at fault (common ones: a missing `#DEBHELPER#` token, or a wrong file mode on a maintainer script). Don't suppress tags.

- [ ] **Step 3: Prove the gate catches a problem**

Temporarily add the line `echo $UNQUOTED` to `build/scripts/build-debs.sh`, then run `make lint`.
Expected: FAIL with SC2086. Remove the line and run `make lint` again. Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add build/scripts/lint.sh
git commit -m "build: add shellcheck + lintian gate"
```

---

### Task 6: Signed local APT repo

**Files:**
- Create: `build/scripts/build-repo.sh`
- Test: `tests/repo/repo.bats`

**Interfaces:**
- Consumes: `out/debs/`, `out/gnupg/`, `out/keyid`, `out/mikos-archive-keyring.gpg` (Task 2).
- Produces: `out/repo/apt/` laid out as `dists/trixie/{Release,InRelease,Release.gpg}`, `pool/main/...` and `mikos-archive-keyring.gpg`. Plan 7 publishes this tree to gh-pages under `/apt`.

- [ ] **Step 1: Write the failing test `tests/repo/repo.bats`**

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test-repo`
Expected: FAIL in `setup_file`, because `out/repo/apt/mikos-archive-keyring.gpg` doesn't exist.

- [ ] **Step 3: Write `build/scripts/build-repo.sh`** (then `chmod +x`)

```bash
#!/usr/bin/env bash
# Publishes out/debs as a signed APT repo at out/repo/apt (suite trixie, component main).
set -euo pipefail
export GNUPGHOME=$PWD/out/gnupg
keyid=$(cat out/keyid)
root=$PWD/out/aptly
rm -rf "$root" out/repo
printf '{"rootDir": "%s", "gpgProvider": "gpg"}\n' "$root" >out/aptly.conf
aptly() { command aptly -config=out/aptly.conf "$@"; }
aptly repo create -distribution=trixie -component=main mikos
aptly repo add mikos out/debs/
aptly publish repo -batch -gpg-key="$keyid" -origin=Mikos -label=Mikos -architectures=amd64 mikos
mkdir -p out/repo/apt
cp -a "$root/public/." out/repo/apt/
cp out/mikos-archive-keyring.gpg out/repo/apt/
```

- [ ] **Step 4: Build and run the test to verify it passes**

Run: `make debs repo test-repo`
Expected: `3 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add build/scripts/build-repo.sh tests/repo/repo.bats
git commit -m "build: signed aptly repo with install test"
```

---

### Task 7: mkosi server image (release + test profile)

**Files:**
- Create: `images/mkosi.conf`
- Create: `images/mkosi.extra/etc/systemd/network/80-dhcp.network`
- Create: `images/mkosi.extra/etc/systemd/system-preset/80-mikos-image.preset`
- Create: `images/mkosi.conf.d/20-test.conf`
- Create: `images/mkosi.test-postinst.chroot`
- Create: `build/scripts/build-image.sh`

**Interfaces:**
- Consumes: `out/debs/` (Tasks 2–4).
- Produces:
  - Release: `out/images/mikos-server.qcow2` and `out/images/mikos-server.vhdx`.
  - Test (`PROFILE=test`): `out/images/mikos-server-test.qcow2`, with user `mikos` (passwordless sudo) whose SSH key is `out/test-ssh/id_ed25519`.

- [ ] **Step 1: Write `images/mkosi.conf`**

Paths are absolute because the build always runs in the container with the repo mounted at `/src`.

```ini
[Distribution]
Distribution=debian
Release=trixie
Repositories=main,non-free-firmware

[Output]
Format=disk
ImageId=mikos-server
OutputDirectory=/src/out/images

[Content]
Bootable=yes
Bootloader=systemd-boot
KernelCommandLine=console=ttyS0 console=tty0
WithDocs=no
Hostname=mikos
PackageDirectories=/src/out/debs
Packages=
        linux-image-amd64
        systemd
        systemd-sysv
        systemd-boot
        systemd-resolved
        udev
        dbus
        mikos-server
```

- [ ] **Step 2: Write the image-only network config**

`images/mkosi.extra/etc/systemd/network/80-dhcp.network`:
```ini
[Match]
Name=en* eth*

[Network]
DHCP=yes
```

`images/mkosi.extra/etc/systemd/system-preset/80-mikos-image.preset`:
```
enable systemd-networkd.service
enable systemd-resolved.service
```

- [ ] **Step 3: Write the test profile**

`images/mkosi.conf.d/20-test.conf`:
```ini
[Match]
Profiles=test

[Output]
ImageId=mikos-server-test

[Content]
Packages=sudo
ExtraTrees=/src/out/test-tree
PostInstallationScripts=/src/images/mkosi.test-postinst.chroot
```

`images/mkosi.test-postinst.chroot` (then `chmod +x`):
```sh
#!/bin/sh
# Test image only: an SSH user for the QEMU smoke tests.
set -e
useradd -m -s /bin/bash -G sudo mikos
install -d -m700 -o mikos -g mikos /home/mikos/.ssh
install -m600 -o mikos -g mikos /etc/mikos-test/authorized_keys /home/mikos/.ssh/authorized_keys
echo 'mikos ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/90-mikos-test
chmod 440 /etc/sudoers.d/90-mikos-test
```

- [ ] **Step 4: Write `build/scripts/build-image.sh`** (then `chmod +x`)

```bash
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
```

- [ ] **Step 5: Build both images**

Run: `make debs image PROFILE=test && make image`
Expected: `out/images/` holds `mikos-server-test.qcow2`, `mikos-server.qcow2` and `mikos-server.vhdx`.

If mkosi rejects a setting (option names change between versions), check against the installed version's docs with `docker run --rm mikos-build:latest mkosi documentation`. Fix the key, keep the intent, and note the change in the commit message.

- [ ] **Step 6: Commit**

```bash
git add images build/scripts/build-image.sh
git commit -m "feat(images): mkosi Mikos Server image with test profile"
```

---

### Task 8: QEMU boot + SSH smoke tests

**Files:**
- Create: `tests/vm/boot.sh`
- Create: `tests/vm/smoke.bats`

**Interfaces:**
- Consumes: `out/images/mikos-server-test.qcow2` and `out/test-ssh/id_ed25519` (Task 7).
- Produces: `make test-vm`. It exports `MIKOS_SSH` (the full ssh command for user `mikos`) and `MIKOS_SSH_OPTS` (options only) to the bats suite. Later plans add their own `tests/vm/*.bats` files that use the same two variables.

- [ ] **Step 1: Write the smoke suite `tests/vm/smoke.bats`**

```bash
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
```

- [ ] **Step 2: Write `tests/vm/boot.sh`** (then `chmod +x`)

```bash
#!/usr/bin/env bash
# Boots the test image in QEMU (UEFI), waits for SSH, runs every tests/vm/*.bats suite.
set -euo pipefail
img=out/images/mikos-server-test.qcow2
key=out/test-ssh/id_ed25519
work=$(mktemp -d)
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
trap 'kill "$(cat "$work/qemu.pid")" 2>/dev/null || true' EXIT

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
```

- [ ] **Step 3: Run it**

Run: `make test-vm`
Expected: `9 tests, 0 failures`. Under TCG (no KVM), boot can take a few minutes.

If `system reaches running state` fails, the test prints the failed units. Fix the cause in the right package or image file and rebuild with `make debs image PROFILE=test test-vm`. Don't loosen the test.

- [ ] **Step 4: Prove a regression is caught**

Temporarily change `PermitRootLogin no` to `PermitRootLogin yes` in `packages/mikos-base/files/etc/ssh/sshd_config.d/50-mikos.conf`, then run `make debs test-pkg`.
Expected: `sshd refuses root and passwords` FAILS. Revert the change and run `make debs test-pkg` again. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/vm
git commit -m "test(vm): QEMU boot and SSH smoke tests"
```

---

### Task 9: Artifact size budgets

**Files:**
- Create: `build/scripts/check-size.sh`

**Interfaces:**
- Consumes: `out/images/mikos-server.qcow2` (Task 7). It also checks `out/iso/mikos-server-*.iso` if one exists (plan 2 creates it).
- Produces: `make size`, which exits non-zero if any budget is exceeded.

- [ ] **Step 1: Write `build/scripts/check-size.sh`** (then `chmod +x`)

```bash
#!/usr/bin/env bash
# Fails if any built artifact exceeds its budget from the spec (§2a).
set -euo pipefail
shopt -s nullglob
fail=0
check() { # file max_mb
	local mb=$(( $(stat -c %s "$1") / 1024 / 1024 ))
	if (( mb > $2 )); then echo "OVER  $1: ${mb}M > $2M"; fail=1; else echo "ok    $1: ${mb}M <= $2M"; fi
}
check out/images/mikos-server.qcow2 1024
for iso in out/iso/mikos-server-*.iso; do check "$iso" 900; done
exit $fail
```

- [ ] **Step 2: Run it**

Run: `make size`
Expected: `ok    out/images/mikos-server.qcow2: <N>M <= 1024M`, exit 0.

- [ ] **Step 3: Prove it fails when over budget**

Run: `docker run --rm -v $PWD:/src -w /src mikos-build:latest bash -c 'sed s/1024/1/ build/scripts/check-size.sh | bash'`
Expected: an `OVER` line and a non-zero exit.

- [ ] **Step 4: Commit**

```bash
git add build/scripts/check-size.sh
git commit -m "build: enforce artifact size budgets"
```

---

### Task 10: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: every Make target from Tasks 1–9.
- Produces: CI on push and PR that runs lint, package, repo and VM tests and the size check, and uploads the release images as a workflow artifact.

- [ ] **Step 1: Write `.github/workflows/ci.yml`**

```yaml
name: ci
on:
  push:
    branches: [master, "claude/**"]
  pull_request:

jobs:
  build-test:
    runs-on: ubuntu-24.04
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4

      - name: Enable KVM for QEMU
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm

      - name: Packages
        run: make debs lint test-pkg

      - name: Repo
        run: make repo test-repo

      - name: VM smoke tests
        run: make image PROFILE=test && make test-vm

      - name: Release image + size budgets
        run: make image && make size

      - uses: actions/upload-artifact@v4
        with:
          name: mikos-server-images
          path: |
            out/images/mikos-server.qcow2
            out/images/mikos-server.vhdx
          retention-days: 7
```

- [ ] **Step 2: Check the workflow locally**

Run: `docker run --rm -v $PWD:/repo -w /repo rhysd/actionlint:1.7.7 -color`
Expected: no output, exit 0.

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build, lint, package/repo/VM tests, size budgets"
git push -u origin <current-branch>
```

- [ ] **Step 4: Verify CI is green**

Open the workflow run for the pushed commit. Expected: every step passes. If a step fails, reproduce it locally with the same `make` target, fix the root cause, and push again.

---

## Phase 1 exit check

- [ ] `make debs lint test-pkg repo test-repo` passes locally
- [ ] `make image PROFILE=test test-vm` passes (9/9)
- [ ] `make image size` passes
- [ ] CI is green on the branch
- [ ] Manual: import `out/images/mikos-server.vhdx` into a Hyper-V Gen2 VM with Secure Boot **off**. It boots to a login prompt showing "Mikos 1.0". (Secure Boot signing is handled in plan 2/7.)
