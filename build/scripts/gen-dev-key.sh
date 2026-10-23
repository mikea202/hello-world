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
