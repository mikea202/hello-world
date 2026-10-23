# Mikos Server 1.0 — Design Spec

Date: 2026-10-23
Status: Approved (design), pending implementation plan

## 1. Summary

Mikos is a Debian 13 (Trixie) remix. Phase 1 ships **server only**, with a governed **AI harness** baked into the base: a local LLM gateway (LiteLLM → OpenRouter) plus two agents — **Hermes Agent** (resident ops daemon) and **Pi** (interactive admin CLI). All customization ships as signed `.deb` packages from a Mikos APT repo; ISOs and VM images just install meta-packages, so installed systems upgrade via `apt`.

Audience: personal/homelab now, agency deployment later (phase 3).

**Design principle: lean.** Every variant installs the minimum needed. Anything non-essential ships as an optional package, never pulled in by default (§2a).

## 2. Scope

### In (phase 1)
- `mikos-base`, `mikos-server`, `mikos-branding` (minimal: os-release, GRUB, motd)
- AI harness: `mikos-ai-gateway`, `mikos-ai` (CLI), `mikos-agent-hermes`, `mikos-agent-pi`
- Optional: `mikos-vanna` (Vanna.ai Docker Compose stack)
- First-boot TUI `mikos-setup`
- Signed APT repo on GitHub Pages
- Outputs: `mikos-server-<ver>-amd64.iso` (live-build, installer), `.qcow2` + `.vhdx` (mkosi)
- Docker-based build, GitHub Actions CI with QEMU boot tests

### Out (later phases)
- Phase 2: `mikos-desktop` (minimal KDE Plasma, Calamares, live ISO), full branding (Plymouth/SDDM/KDE), **Amazon WorkSpaces client** (`mikos-desktop` depends on it). Risk: AWS officially supports the Linux client on Ubuntu, not Debian. Verify at phase 2 planning that it installs and runs on Debian 13; fallback options are repackaging the Ubuntu .deb with fixed dependencies, or a Flatpak/container wrapper.
- Phase 3: `mikos-corp` (realmd/sssd AD join, Entra SSO via himmelblau, Defender for Endpoint, CIS L1, enforced LUKS)
- Local LLM inference / GPU drivers (no capable hardware; internet + OpenRouter required)
- arm64

### Constraints
- Internet access required for AI features (OpenRouter).
- Intune does not officially support Debian. If Intune compliance becomes mandatory in phase 3, rebase to Ubuntu LTS; keep packages distro-portable (no Debian-only hacks where avoidable).
- Agent availability depends on upstream projects (Hermes: NousResearch; Pi: badlogic/Earendil). Versions pinned; agents are pluggable behind the gateway.

## 2a. Lean policy (all variants)

- `APT::Install-Recommends "false"` and `APT::Install-Suggests "false"` set in mikos-base, the installer, and the image builds
- dpkg `path-exclude` drop-in: drop `/usr/share/doc/*` (except copyright files), non-English locales, and translated man pages. English man pages stay.
- Meta-packages only `Depends` on essentials. Extras go in **optional** packages that are never `Recommends`:
  - `mikos-pwsh` (PowerShell 7)
  - `mikos-docker` (Docker CE + compose). Pulled in only by `mikos-vanna` or on request.
  - `mikos-cockpit` (Cockpit web admin)
  - `mikos-vanna`
- No firmware blobs beyond `firmware-linux-free` by default. The installer adds hardware firmware only when detected.
- Single kernel flavor; old kernels autoremoved
- Size budgets enforced in CI (build fails if exceeded):
  - server ISO ≤ 900 MB
  - server installed footprint ≤ 2.0 GB including the AI stack (≤ 1.2 GB without the AI packages)
  - qcow2 image ≤ 1.0 GB compressed
  - Phase 2 desktop: ISO ≤ 2.5 GB, installed ≤ 6 GB (targets, revisit then)
- AI stack trimmed: one shared Node LTS runtime (only Pi uses it), venvs built with `--no-cache` and with bytecode/tests stripped. `mikos-ai-gateway` installs the LiteLLM proxy extras only.

## 3. Repository layout

```
packages/
  mikos-base/
  mikos-server/
  mikos-branding/
  mikos-ai-gateway/
  mikos-ai/
  mikos-agent-hermes/
  mikos-agent-pi/
  mikos-setup/
  mikos-vanna/
repo/            # aptly config; published output → gh-pages
iso/             # live-build config (server installer ISO)
images/          # mkosi config (qcow2, vhdx)
build/           # Dockerfile, Makefile, signing helpers
tests/           # QEMU boot + smoke tests
.github/workflows/
docs/
```

Versioning: Mikos `1.x` = Debian 13. Point releases = package updates only. Packages versioned `1.0.0-1` etc.

## 4. Packages

### mikos-base
- APT sources: Debian 13 main/contrib/non-free-firmware + Mikos repo + signing key (`/usr/share/keyrings/mikos.gpg`)
- `/etc/os-release` → `ID=mikos`, `ID_LIKE=debian`, `VERSION_ID=1.0`
- sshd hardening drop-in: no root login, key-only auth
- sysctl hardening drop-in (kptr_restrict, rp_filter, no redirects, etc.)
- nftables: default-deny inbound, allow established + SSH; egress rules from mikos-ai-gateway (§5)
- unattended-upgrades: security only, Mikos repo included
- auditd + rules; AppArmor enforced
- chrony
- CLI tools (minimal): vim-tiny, htop, curl, git, jq, tmux. PowerShell 7 moves to optional `mikos-pwsh`.

Config files are shipped as drop-ins (`*.d/`) wherever possible to avoid conffile conflicts with Debian packages.

### mikos-server
- Depends: mikos-base
- fail2ban (sshd jail)
- No GUI
- Docker and Cockpit are not included. Install them with `mikos-docker` / `mikos-cockpit` (Cockpit binds to localhost by default; opening port 9090 is opt-in).

### mikos-branding (minimal in phase 1)
- os-release values, GRUB theme/name, `/etc/issue`, motd

## 5. AI harness

### 5.1 Architecture

```
 agents (hermes / pi / mikos-ai / vanna)
        │  OPENAI_BASE_URL=http://127.0.0.1:4000/v1, per-agent virtual key
        ▼
 mikos-ai-gateway  (LiteLLM proxy, systemd, user: mikos-ai)
   • only holder of the OpenRouter key
   • per-agent virtual keys, budgets, model allowlists
   • logs every request/response/cost
        ▼
 nftables egress: only uid mikos-ai may reach openrouter.ai:443
```

### 5.2 mikos-ai-gateway
- LiteLLM proxy in pinned uv venv at `/opt/mikos/litellm`; binds `127.0.0.1:4000` only
- systemd unit, user `mikos-ai`, hardened (`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, etc.)
- OpenRouter key stored via `systemd-creds` (encrypted, `LoadCredentialEncrypted=`); never in env files readable by agents
- Config `/etc/mikos/ai/gateway.yaml`: model allowlist, default model, per-key budgets
- Virtual-key DB: SQLite at `/var/lib/mikos-ai/`
- Audit: JSON lines to `/var/log/mikos-ai/audit.jsonl` (timestamp, agent key, model, tokens, cost, prompt, response) + journald summary; logrotate config
- Egress: nftables `meta skuid mikos-ai` allowed to resolved openrouter.ai on 443; other agent users denied outbound 443 to AI endpoints (agents still need general egress for apt/pip/git — enforced by policy at gateway, not full egress lockdown in phase 1)

### 5.3 mikos-ai (CLI)
- `mikos-ai status` — gateway health, spend per agent, current model
- `mikos-ai on|off` — enable/disable all AI (stops gateway → all agents lose model access)
- `mikos-ai key set` — set/rotate OpenRouter key (writes systemd-creds)
- `mikos-ai agent add|list|budget|revoke <name>` — manage virtual keys
- `mikos-ai ask "<question>"` — runs default agent (Hermes) with **read-only tool profile** (journalctl, systemctl status, df, ss, cat /etc, plus docker ps when mikos-docker is installed); returns answer
- `mikos-ai audit [--agent X] [--since ...]` — query audit log

### 5.4 Agent sandbox (shared rules)
- Each agent = own system user (`hermes`, `pi`) with home in `/var/lib/<agent>`
- Root only via `/etc/sudoers.d/mikos-agents` allowlist: `systemctl`, `journalctl`, `apt`, `apt-get`, plus `docker` when mikos-docker is installed (exact command paths; no shell, no editors)
- auditd rules key every execve by agent uids (`-k mikos-agent`)
- Agents receive only their gateway virtual key (via `LoadCredential=`), never the OpenRouter key

### 5.5 mikos-agent-hermes (resident ops daemon)
- Pinned Hermes Agent release in uv venv at `/opt/mikos/hermes`
- systemd unit as `hermes`; `~/.hermes/config.yaml` pre-set to gateway base URL + virtual key
- Ships Mikos skills: system health summary, log triage, service restart (via sudo allowlist), apt update report
- Optional Telegram/Discord gateway configured by `mikos-setup` (off by default)
- Default role for `mikos-ai ask`

### 5.6 mikos-agent-pi (interactive admin CLI)
- Pinned Pi npm package + bundled Node LTS at `/opt/mikos/pi`; wrapper `/usr/bin/pi`
- When admin runs `pi`, it runs under the admin's own user with the admin's own virtual key (issued by `mikos-setup`); a `pi-agent` mode can run as the `pi` user for unattended tasks
- Provider config points at gateway (OpenAI-compatible)
- Ships a Mikos extension: tools for `mikos-ai status/audit`, safe-command guard (confirm before destructive ops)
- No MCP (Pi design choice); integrations via Pi extensions

### 5.7 mikos-vanna (optional)
- Depends: `mikos-docker`
- Docker Compose stack in `/opt/mikos/vanna`: Vanna + vector DB (Chroma) + web UI
- LLM calls via gateway (own virtual key)
- Not installed by default; `apt install mikos-vanna`

## 6. First boot: mikos-setup

TUI (whiptail/dialog), runs once on first console/SSH login as root, re-runnable:
1. Hostname, timezone
2. Admin user + SSH public key; disable password auth
3. OpenRouter API key → `mikos-ai key set` (validated with a test call)
4. Default model pick (from allowlist)
5. Create virtual keys: hermes, pi-agent, admin
6. Optional: Hermes Telegram/Discord gateway
7. Optional extras: mikos-docker, mikos-cockpit, mikos-pwsh, mikos-vanna (all unchecked by default)
8. Summary + mark complete (`/var/lib/mikos/setup-done`)

Skippable AI steps — system must work fully without AI configured.

## 7. Build

- `build/Dockerfile`: Debian 13 image with devscripts, debhelper, live-build, mkosi, aptly, qemu, uv, node
- `Makefile` targets: `debs`, `repo`, `iso`, `image`, `test`, `all`
- Works identically on Windows 11 (Docker Desktop / WSL2) and GitHub Actions
- Venv/Node payloads built in CI from pinned lockfiles (`uv.lock`, `package-lock.json`), packaged into debs; **no network fetches at package install time**
- Repo signing key: GPG key stored as GitHub Actions secret; public key shipped in mikos-base

## 8. Testing

Per PR:
- lintian on all debs (fail on errors)
- shellcheck on scripts
- Unit tests for `mikos-ai` CLI (pytest; gateway mocked)

Per main/tag (QEMU, KVM if available):
- Boot ISO unattended (preseed) → install → reboot → SSH smoke tests
- Boot mkosi qcow2 → same smoke tests

Smoke tests:
- sshd, nftables, auditd, fail2ban, mikos-ai-gateway, hermes active
- Docker **not** installed by default; no Recommends were pulled in (`apt-mark showauto` diff vs the expected manifest)
- Size budgets from §2a met
- Root SSH login refused; password auth refused
- Gateway answers `/v1/chat/completions` via mock upstream (fake OpenRouter in test)
- Agent user cannot reach openrouter.ai directly; can reach gateway
- Agent sudo: allowed command works, disallowed command (`sudo bash`) denied
- Audit log entry written per gateway call
- `mikos-ai off` → agent request fails; `on` → succeeds

## 9. Release

- Tag `vX.Y.Z` → CI: build debs → publish signed aptly repo to gh-pages → build ISO + images → attach to GitHub Release with SHA256SUMS (signed)

## 10. Error handling

- Gateway down / no key: agents and `mikos-ai ask` fail with clear message ("AI disabled or not configured — run mikos-ai status"); base system unaffected
- OpenRouter errors/rate limits: LiteLLM retries + fallback model list from gateway.yaml
- Budget exceeded: gateway rejects with 429; logged; `mikos-ai status` shows it
- Bad/expired key: `mikos-setup`/`key set` validate before saving
- Package upgrades: configs as drop-ins + debconf; agent state in `/var/lib/<agent>` preserved across upgrades

## 11. Done criteria (phase 1)

- ISO installs in Hyper-V and Proxmox VMs
- `mikos-setup` completes
- `mikos-ai ask "summarize system health"` returns an answer
- That call appears in `mikos-ai audit`
- `apt upgrade` from the Mikos repo upgrades all Mikos packages cleanly
- All CI smoke tests green

## 12. Open items for planning
- Exact pinned versions of Hermes, Pi, LiteLLM, Node LTS (resolve at plan time)
- Pi npm scope (`@mariozechner` vs `@earendil-works`) — confirm current
- Initial model allowlist / default model on OpenRouter
- Confirm the size budgets are realistic after the first build; tune them
- Phase 2: Amazon WorkSpaces Linux client on Debian 13 (see §2 Out)
