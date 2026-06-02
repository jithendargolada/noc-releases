# NethraOps agent - package + repo signing (Phase 1D)

This directory owns the GPG signing flow for the Linux .deb / .rpm packages
and for the APT (`Release` / `InRelease`) + YUM (`repomd.xml`) repository
metadata served by the GitHub Pages hosted repo.

## Files

| file | what |
| --- | --- |
| `gen-key.conf` | unattended `gpg --batch --gen-key` config (4096-bit RSA, 3-year expiry, no passphrase by default) |
| `generate-key.sh` | one-shot key generator. Writes `nethraops-repo-pubkey.asc`, prints `gh secret set` commands |
| `sign-deb.sh` | `debsigs --sign=origin` wrapper around one or more .deb files |
| `sign-rpm.sh` | `rpm --addsign` wrapper around one or more .rpm files (materialises a temporary `.rpmmacros`) |
| `sign-repo-metadata.sh` | `gpg --detach-sign` + `--clearsign` over `Release` / `repomd.xml` |
| `nethraops-repo-pubkey.asc` | ASCII-armored public key. **DEMO ONLY** key generated on the Phase 1D build host; customer MUST regenerate before going live |

## Quick start (operator)

```bash
# 1. Generate the key. Pick an email tied to your tenant so a future
#    rotation has a unique uid:
NETHRAOPS_REPO_KEY_EMAIL=repo-signing@example.com bash generate-key.sh

# 2. Export the private key into the repo's GitHub Encrypted Secrets:
gpg --armor --export-secret-keys <KEYID> | \
    gh secret set GPG_PRIVATE_KEY -R your-org/your-repo
gh secret set GPG_KEY_ID    -R your-org/your-repo -b '<KEYID>'
gh secret set GPG_PASSPHRASE -R your-org/your-repo -b ''   # blank if no-passphrase

# 3. Commit the public key (nethraops-repo-pubkey.asc) so customers can
#    apt-key import it.
```

## Demo key in this repo

`nethraops-repo-pubkey.asc` was generated on the dev box during Phase 1D
implementation so the included `.deb` + `dists/stable/Release.gpg` +
`dists/stable/InRelease` + `repodata/repomd.xml.asc` artifacts verify
end-to-end with `gpg --verify`. The corresponding **private key** was
left in an ephemeral `GNUPGHOME` and is not retained anywhere - regenerate
your own key before your first real release. The committed signatures
are useful for verifying the build pipeline produces well-formed output;
they are not a valid identity for a production tenant.

To prove the demo verifies:

```bash
gpg --import agent/packaging/signing/nethraops-repo-pubkey.asc
gpg --verify agent/packaging/linux/repos/apt/dists/stable/Release.gpg \
             agent/packaging/linux/repos/apt/dists/stable/Release
gpg --verify agent/packaging/linux/repos/apt/dists/stable/InRelease
gpg --verify agent/packaging/linux/repos/yum/repodata/repomd.xml.asc \
             agent/packaging/linux/repos/yum/repodata/repomd.xml
gpg --verify agent/packaging/linux/deb/dist/nethraops-agent_0.1.0_all.deb.asc \
             agent/packaging/linux/deb/dist/nethraops-agent_0.1.0_all.deb
```

## Customer-side verification

The Phase 1C `docs/linux-deployment/README.md` ships the user-facing
install snippet. The relevant flow:

```bash
# Trust the key under the modern, apt-key-deprecated keyring path:
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://<pages-url>/keys/nethraops-repo-pubkey.asc \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nethraops-monitor.gpg

# Tell apt where the repo is + which key signs it (signed-by= is the
# replacement for `apt-key add` since apt 1.1; required from Debian 12
# / Ubuntu 22.04 onwards):
echo "deb [signed-by=/etc/apt/keyrings/nethraops-monitor.gpg] \
https://<pages-url>/apt stable main" \
    | sudo tee /etc/apt/sources.list.d/nethraops-monitor.list

sudo apt update
sudo apt install -y nethraops-agent
```

For RPM hosts (DNF reads the `gpgkey=` URL on first `dnf install`; it
prompts before importing if `gpgcheck=1` is set):

```bash
sudo tee /etc/yum.repos.d/nethraops-monitor.repo <<'EOF'
[nethraops-monitor]
name=NethraOps agent
baseurl=https://<pages-url>/yum
enabled=1
gpgcheck=1
gpgkey=https://<pages-url>/keys/nethraops-repo-pubkey.asc
repo_gpgcheck=1
EOF
sudo dnf install -y nethraops-agent
```

## Rotation

1. Generate a new key with a distinct uid (e.g. `repo-signing-2027@...`).
2. Publish the new public key alongside the old one under
   `/keys/nethraops-repo-pubkey-2027.asc`. Update the canonical
   `/keys/nethraops-repo-pubkey.asc` symlink last (so customers who fetch
   the old name during the transition still get a key that signs the
   current repo metadata).
3. Re-sign the existing repo metadata with BOTH keys for at least one
   `apt update` cycle (90 days is the default operator window) so
   customers in the field can `apt update` once with the old key, drop
   it, and install the new one.
4. Revoke the old key once telemetry shows zero installs running the
   stale keyring. `gpg --gen-revoke <OLDKEYID>` -> publish the revoke
   cert at `/keys/nethraops-repo-pubkey-revoke.asc`.

## CI secret matrix

Configured under repo Settings -> Secrets and variables -> Actions:

| secret | what | required? |
| --- | --- | --- |
| `GPG_PRIVATE_KEY` | ASCII-armored output of `gpg --armor --export-secret-keys <KEYID>` | yes |
| `GPG_KEY_ID` | 16-hex-char key id | yes |
| `GPG_PASSPHRASE` | passphrase for the private key, or `` if none | yes (may be blank) |
| `WIN_SIGNING_CERT` | base64-encoded .pfx for Authenticode | no (Phase 1E) |
| `WIN_SIGNING_PASSPHRASE` | passphrase for the .pfx | no (Phase 1E) |

GitHub Encrypted Secrets docs:
<https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions>
