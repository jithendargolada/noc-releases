# GitHub Actions secrets matrix (Phase 1D)

The `publish-packages.yml` workflow needs the following secrets
configured under repo **Settings -> Secrets and variables -> Actions**.

## Required (GPG)

| name | what | how to generate |
| --- | --- | --- |
| `GPG_PRIVATE_KEY` | ASCII-armored output of `gpg --armor --export-secret-keys <KEYID>` | `bash agent/packaging/signing/generate-key.sh`, then `gpg --armor --export-secret-keys <KEYID>` |
| `GPG_KEY_ID` | 16-hex-char key id (uppercase). The same string that appears in `gpg --list-keys --keyid-format=long` after `pub  rsa4096/` | printed at the end of `generate-key.sh` |
| `GPG_PASSPHRASE` | passphrase for the private key, or empty string if the key was generated with `%no-protection` (the default in `gen-key.conf`) | whatever you set when running `gpg --gen-key`; if you used the unattended config it is empty |

The simplest path (TRUSTED workstation only):

```bash
bash agent/packaging/signing/generate-key.sh
KEYID=$(gpg --list-keys --with-colons repo-signing@nethraops.local \
        | awk -F: '/^pub:/ {print $5; exit}')

gpg --armor --export-secret-keys "$KEYID" \
    | gh secret set GPG_PRIVATE_KEY -R your-org/your-repo
gh secret set GPG_KEY_ID    -R your-org/your-repo -b "$KEYID"
gh secret set GPG_PASSPHRASE -R your-org/your-repo -b ''
```

## Optional (Windows Authenticode)

| name | what | how to generate |
| --- | --- | --- |
| `WIN_SIGNING_CERT` | base64-encoded `.pfx` containing an EV or OV code-signing cert | `base64 -w0 nethraops-codesign.pfx \| gh secret set WIN_SIGNING_CERT` |
| `WIN_SIGNING_PASSPHRASE` | passphrase for the `.pfx` | `gh secret set WIN_SIGNING_PASSPHRASE -b '<pwd>'` |

If these are NOT set, the workflow still builds the MSI / EXE but
ships them unsigned. Customers will see the Windows SmartScreen
"unrecognized publisher" prompt; that is acceptable for a beta but
must be addressed before GA. Cert procurement is a Phase 1E task.

## Verification

After populating the secrets, push a test tag to a throwaway branch:

```bash
git tag agent-v0.0.0-test
git push origin agent-v0.0.0-test
```

Watch the workflow under the **Actions** tab. A green run uploads to
`https://<your-org>.github.io/<your-repo>/`. Delete the test tag once
you've confirmed.

## GitHub docs

* Encrypted Secrets: <https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions>
* Configuring Pages: <https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site>
* deploy-pages action: <https://github.com/actions/deploy-pages>
