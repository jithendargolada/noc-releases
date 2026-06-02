# NethraOps - Linux package repositories

This directory holds the **on-disk repository layouts** for the
nethraops-agent DEB and RPM packages. Phase 1C generates the
layouts under `apt/` and `yum/`; Phase 1D wires them up to a GPG
signing pass + a GitHub Pages publish job.

## Layout

```
repos/
  apt/
    pool/main/a/nethraops-agent/         .deb files (any version)
    dists/stable/main/binary-amd64/
      Packages
      Packages.gz
    dists/stable/Release
    dists/stable/Release.gpg                   detached signature (Phase 1D)
    dists/stable/InRelease                     clearsigned wrapper (Phase 1D)
    build-repo.sh                              regenerate Packages + Release
  yum/
    noarch/                                    .rpm files
    repodata/                                  repomd.xml + indexes
    repodata/repomd.xml.asc                    detached signature (Phase 1D)
    build-repo.sh                              regenerate repodata
  _site/
    index.html                                 landing-page template
                                                (envsubst-rendered by CI)
```

Rebuild after dropping a new `.deb` / `.rpm` into the corresponding
sub-tree:

```
bash agent/packaging/linux/deb/build.sh
bash agent/packaging/linux/repos/apt/build-repo.sh

bash agent/packaging/linux/rpm/build.sh           # on a Rocky/RHEL host
bash agent/packaging/linux/repos/yum/build-repo.sh

# Phase 1D signing pass:
GPG_KEY_ID=<YOURKEYID> bash agent/packaging/signing/sign-repo-metadata.sh agent/packaging/linux/repos
```

## Hosting target: GitHub Pages (Phase 1D pick)

Phase 1D ships with **GitHub Pages** as the canonical hosting target.
Reasons: free, zero infra, the customer repo already has Pages on the
premium/enterprise plan, no per-build secrets beyond a GPG key.

The CI workflow at `.github/workflows/publish-packages.yml` runs on
each `agent-v*` tag push and publishes the `_site/` tree to Pages.

Canonical published URL pattern:

```
https://<user-or-org>.github.io/<repo>/
```

Under that root:

| path | what |
| --- | --- |
| `apt/` | APT repo tree (`pool/`, `dists/stable/`, signed Release+InRelease) |
| `yum/` | YUM repo tree (`noarch/`, `repodata/`, signed repomd.xml.asc) |
| `windows/NethraOpsMonitorAgent.msi` | Latest MSI (stable URL across releases) |
| `windows/NethraOpsMonitorAgentBootstrap.exe` | Latest bootstrapper EXE |
| `windows/NethraOpsMonitorAgent-<version>.msi` | Versioned MSI |
| `keys/nethraops-repo-pubkey.asc` | Repo signing public key |
| `index.html` | Landing page with copy-paste install snippets |

### Custom domain (optional)

Drop a `CNAME` file at the root of the `gh-pages` branch (or under
`_site/` so the deploy-pages action picks it up):

```
repo.nethraops.example
```

Then update DNS to CNAME `repo.nethraops.example -> <user>.github.io`
and the Pages site serves under the custom domain. The published
APT / YUM snippets in `_site/index.html` use relative URLs so they
keep working under either hostname.

## Client-side configuration (after publish)

`/etc/apt/sources.list.d/nethraops-monitor.list`:

```
deb [signed-by=/etc/apt/keyrings/nethraops-monitor.gpg] https://<pages-url>/apt stable main
```

`/etc/yum.repos.d/nethraops-monitor.repo`:

```
[nethraops-monitor]
name=NethraOps agent
baseurl=https://<pages-url>/yum
enabled=1
gpgcheck=1
gpgkey=https://<pages-url>/keys/nethraops-repo-pubkey.asc
repo_gpgcheck=1
```

The published `index.html` renders both snippets with the actual
URLs for cut-and-paste convenience.

## Other hosting options (not used by Phase 1D)

For future reference if the GitHub Pages limits become a problem
(soft 1GB / 100GB monthly bandwidth):

1. **S3 + CloudFront static site.** Sync the `repos/` directory with
   `aws s3 sync --delete`. CloudFront fronts the bucket with a custom
   domain + TLS. The `Release` / `repomd.xml` files must be served
   with `Cache-Control: no-cache` so apt/dnf see new releases
   immediately.
2. **Dedicated nginx box.** Just `rsync` the `repos/` dir to
   `/var/www/repo.nethraops.example/`. Best for air-gapped customers
   running an on-prem mirror.
3. **Cloudsmith / packagecloud.io / Artifactory.** Managed SaaS
   repository hosts. Higher cost, but handles the signing, the
   `InRelease` rotation, and per-customer entitlement tokens.

## Signing

Phase 1D signing wiring lives in `agent/packaging/signing/`:

```
GPG_KEY_ID=<YOURKEYID> bash agent/packaging/signing/sign-repo-metadata.sh agent/packaging/linux/repos
```

Produces `apt/dists/stable/Release.gpg`, `apt/dists/stable/InRelease`,
and `yum/repodata/repomd.xml.asc`. See `agent/packaging/signing/README.md`
for the full operator guide (key gen, rotation, CI secret loading).
