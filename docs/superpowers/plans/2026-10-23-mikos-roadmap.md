# Mikos Server 1.0 — Roadmap

Spec: `docs/superpowers/specs/2026-10-23-mikos-server-design.md`

The spec covers several independent subsystems. Each one gets its own plan → implementation → review cycle, in this order. Each plan produces working, testable software on its own.

| # | Sub-project | Delivers | Depends on | Plan |
|---|---|---|---|---|
| 1 | Foundation | Build container, Makefile, `mikos-base`, `mikos-server`, `mikos-branding` (minimal), signed local APT repo, mkosi qcow2/vhdx image, QEMU boot + SSH smoke tests, size checks, CI | — | `2026-10-23-mikos-p1-foundation.md` |
| 2 | Installer ISO + first boot | live-build server ISO (role select: server/router), preseed for unattended test installs, `mikos-setup` TUI (non-AI steps), ISO QEMU install test | 1 | to write |
| 3 | AI gateway | `mikos-ai-gateway` (LiteLLM venv, systemd-creds key, virtual keys, audit log, egress nftables), `mikos-ai` CLI (status/on/off/key/agent/audit), mock-OpenRouter tests, `mikos-setup` AI steps | 1 | to write |
| 4 | Agents | `mikos-agent-hermes`, `mikos-agent-pi`, agent users + sudo allowlist + auditd keys, Mikos skills/extension, `mikos-ai ask` | 3 | to write |
| 5 | Router core | `mikos-router` CLI (validate/diff/apply/confirm/rollback/status), pure renderer → networkd/nftables/Kea/Unbound, blocklist timer, proposals dir, router-safe sudoers, `mikos-setup` router steps, 3-VM QEMU topology tests | 1, 2 (role), 4 (router-safe sudoers) | to write |
| 6 | Router IDS | `mikos-router-ids` (Suricata NFQUEUE IPS, ET Open timer, eve.json in `status`), Hermes `router-advisor` skill, IDS topology test | 5 | to write |
| 7 | Extras + release | `mikos-docker`, `mikos-cockpit`, `mikos-pwsh`, `mikos-vanna`; tag-triggered release (gh-pages repo, ISO/images, signed SHA256SUMS); done-criteria run on Hyper-V + Proxmox | 1–6 | to write |

Pinned versions (Hermes, Pi, LiteLLM, Node LTS) and the Pi npm scope are resolved at the start of plans 3 and 4.
