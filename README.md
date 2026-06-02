# NethraOps — Releases

Public release repository for the **NethraOps agent**: signed Debian / RPM packages, Windows MSI + bootstrapper EXE, the APT and YUM repository metadata, and the GPG public key customers use to verify everything.

Built and signed by the GitHub Actions workflow in this repo; published to GitHub Pages.

## What's here

| Path | Purpose |
|---|---|
| `agent/src/` | Agent Python source (the same code that ships in the .deb / .rpm / MSI) |
| `agent/packaging/linux/{deb,rpm,repos}/` | Linux packaging sources and APT/YUM repo skeletons |
| `agent/packaging/windows/{msi,bootstrap,intune}/` | Windows MSI sources, Burn bootstrapper EXE, Intune wrapper |
| `agent/packaging/signing/` | GPG signing scripts and the **public** signing key (`nethraops-repo-pubkey.asc`) |
| `.github/workflows/publish-packages.yml` | Tag-driven release pipeline (build → sign → publish) |

## How a release happens

1. Tag a commit `agent-v<X.Y.Z>` (matching the version in `agent/pyproject.toml`).
2. The workflow builds: `.deb` (Ubuntu runner), `.rpm` (Rocky 9 container), `.msi` + bootstrapper `.exe` (Windows runner).
3. Linux artifacts are signed with the GPG key configured under repo Secrets (`GPG_PRIVATE_KEY` / `GPG_KEY_ID` / `GPG_PASSPHRASE`).
4. APT (`Release` + `InRelease`) and YUM (`repomd.xml.asc`) metadata is regenerated and signed.
5. Everything is assembled into `_site/` and deployed to Pages.

Live release URL: `https://jithendargolada.github.io/noc-releases`

## How customers consume it

**Debian / Ubuntu:**
```bash
curl -fsSL https://jithendargolada.github.io/noc-releases/keys/nethraops-repo-pubkey.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/nethraops-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nethraops-keyring.gpg] \
  https://jithendargolada.github.io/noc-releases/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/nethraops.list
sudo apt-get update && sudo apt-get install nethraops-agent
```

**Rocky / RHEL / Fedora:**
```bash
sudo rpm --import https://jithendargolada.github.io/noc-releases/keys/nethraops-repo-pubkey.asc
sudo tee /etc/yum.repos.d/nethraops.repo <<EOF
[nethraops]
name=NethraOps
baseurl=https://jithendargolada.github.io/noc-releases/yum
gpgcheck=1
gpgkey=https://jithendargolada.github.io/noc-releases/keys/nethraops-repo-pubkey.asc
enabled=1
EOF
sudo dnf install nethraops-agent
```

**Windows:**
Download the MSI or bootstrapper EXE from `https://jithendargolada.github.io/noc-releases/windows/`.

## Signing key

- Key id: `19910A8B1D12BED2`
- Fingerprint: `1BD91DBF883A5769D46ED4A719910A8B1D12BED2`
- Uid: `NethraOps Repo Signing <repo-signing@nethraops.local>`
- Expires: 2029-06-01 (rotate by then; see `agent/packaging/signing/README.md`)

Verify with:
```bash
gpg --show-keys https://jithendargolada.github.io/noc-releases/keys/nethraops-repo-pubkey.asc
```

## Source of truth

The platform source (backend, frontend, internal services) lives in a private repo. This `noc-releases` repo holds the public release surface of the **agent** — the code that runs on customer machines. `agent/` here is a snapshot synced from the platform repo at each release tag.
