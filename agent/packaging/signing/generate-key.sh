#!/usr/bin/env bash
#
# Generate the NethraOps repository signing key (Phase 1D).
#
# This script is INTERACTIVE-OPTIONAL: with `gen-key.conf` driving it,
# `gpg --batch --gen-key` runs unattended. The output is:
#
#   1. A new 4096-bit RSA key in the active GNUPGHOME.
#   2. agent/packaging/signing/nethraops-repo-pubkey.asc (ASCII-armored
#      public key - SAFE to commit, this is what customers download
#      to verify packages).
#   3. Instructions printed to stdout explaining how to export the
#      PRIVATE key for the GitHub Encrypted Secret `GPG_PRIVATE_KEY`.
#
# NEVER commit the private key. The `--allow-secret-key-import` /
# `--export-secret-keys` operations below stream the key to STDOUT;
# pipe it directly into `gh secret set ...` or into `pass` /
# `bitwarden` / etc. - do not leave it on disk.
#
# Operator workflow:
#   $ cd agent/packaging/signing
#   $ bash generate-key.sh
#   $ # stash the printed PRIVATE key export command output into
#   $ # GitHub Secret GPG_PRIVATE_KEY (and the key id into GPG_KEY_ID)
#
# Rotation: generate a new key, publish the new public key under
# /keys/nethraops-repo-pubkey-<year>.asc on the Pages site, keep the
# OLD key valid for 90 days so customers can apt-update once with the
# old key, install the new one, then drop the old one.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBKEY_OUT="${HERE}/nethraops-repo-pubkey.asc"
CONFIG="${HERE}/gen-key.conf"
EMAIL="${NETHRAOPS_REPO_KEY_EMAIL:-repo-signing@nethraops.local}"

if ! command -v gpg >/dev/null 2>&1; then
    echo "ERROR: gpg not found on PATH. Install GnuPG (gnupg2 on Debian/Ubuntu)." >&2
    exit 127
fi

if [ ! -f "${CONFIG}" ]; then
    echo "ERROR: ${CONFIG} missing." >&2
    exit 1
fi

echo "==> Generating NethraOps repo signing key"
echo "    GNUPGHOME=${GNUPGHOME:-${HOME}/.gnupg}"
echo "    Config:    ${CONFIG}"
echo "    Email:     ${EMAIL}"
echo

# Detect an existing key with the same uid and bail rather than silently
# creating duplicates. Operators rotate by passing NETHRAOPS_REPO_KEY_EMAIL
# (e.g. repo-signing-2026@nethraops.local) so each rotation has a distinct
# uid and the old key remains importable from the Pages site.
if gpg --list-keys --with-colons "${EMAIL}" 2>/dev/null | grep -q '^pub:'; then
    echo "WARN: a key for <${EMAIL}> already exists." >&2
    echo "       Set NETHRAOPS_REPO_KEY_EMAIL to a distinct uid to rotate," >&2
    echo "       or delete the existing key first:" >&2
    echo "         gpg --delete-secret-keys ${EMAIL}" >&2
    echo "         gpg --delete-keys        ${EMAIL}" >&2
    exit 2
fi

gpg --batch --gen-key "${CONFIG}"

KEY_ID="$(gpg --list-keys --with-colons "${EMAIL}" \
    | awk -F: '/^pub:/ {print $5; exit}')"

if [ -z "${KEY_ID}" ]; then
    echo "ERROR: key generation appeared to succeed but no key id found for ${EMAIL}" >&2
    exit 3
fi

echo "==> Exporting public key to ${PUBKEY_OUT}"
gpg --armor --export "${KEY_ID}" > "${PUBKEY_OUT}"
chmod 0644 "${PUBKEY_OUT}"

cat <<EOF

==> Key generated.
    Key id:     ${KEY_ID}
    Uid:        NethraOps Repo Signing <${EMAIL}>
    Public key: ${PUBKEY_OUT}

Next steps:

  1. Verify the public key looks sane:
       gpg --show-keys ${PUBKEY_OUT}

  2. Export the PRIVATE key + load it into GitHub Encrypted Secrets.
     Run this on a TRUSTED workstation. Do NOT commit the output.
       gpg --armor --export-secret-keys ${KEY_ID} | \\
           gh secret set GPG_PRIVATE_KEY -R <your-org>/<your-repo>
       gh secret set GPG_KEY_ID    -R <your-org>/<your-repo> -b '${KEY_ID}'
       gh secret set GPG_PASSPHRASE -R <your-org>/<your-repo> -b ''

     (Leave GPG_PASSPHRASE empty if you generated a no-protection key
      via the default gen-key.conf. Add a passphrase by editing
      gen-key.conf BEFORE running this script; rotate by re-running
      with a distinct NETHRAOPS_REPO_KEY_EMAIL.)

  3. Commit ${PUBKEY_OUT} - it is safe to publish.

  4. To revoke: gpg --gen-revoke ${KEY_ID} > revoke-${KEY_ID}.asc
     then publish the revocation cert alongside the public key. Keep
     the revoke cert in a secure offline location.

EOF
