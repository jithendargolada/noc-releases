# NethraOps agent - Windows bootstrapper (Phase 1D)

A WiX Burn `.exe` that wraps the Phase 1B MSI plus a Python 3.11
embeddable distribution so the agent installs cleanly on Windows hosts
that do NOT already have Python 3.11+ on PATH.

## When to ship which artifact

| artifact | when to use |
| --- | --- |
| `NethraOpsMonitorAgent-<v>.msi` (Phase 1B) | Managed hosts where Python 3.11+ is centrally provisioned (e.g. via SCCM, Chef, or already part of the gold image). Smaller download; faster install; Intune / GPO friendly. |
| `NethraOpsMonitorAgentBootstrap-<v>.exe` (Phase 1D) | Fresh hosts with no Python. Self-contained: downloads the python.org embeddable on demand, lays it down at `C:\Program Files\NethraOpsAgent\python\`, then invokes the MSI with `PYTHON_PATH=` pointing at the embeddable. |

The bootstrapper EXE accepts the same operator-supplied properties as
the MSI:

    NethraOpsMonitorAgentBootstrap-0.2.0.exe /quiet `
        CLAIM_TOKEN=acmeXXXXXXXX `
        PLATFORM_URL=https://monitor.acme.com `
        DEVICE_GROUP=prod-east `
        HOST_LABEL=db-east-01

## Build

```powershell
# On a Windows host with WiX 3.11+ or WiX 4.x installed.
cd agent\packaging\windows\bootstrap
.\build.ps1 -Version 0.2.0 `
    -MsiPath ..\msi\dist\NethraOpsMonitorAgent-0.2.0.msi `
    -PythonZipSha512 <128-hex-chars-from-python.org-checksums>
```

CI runs the same script on the `build-bootstrap` job in
`.github/workflows/publish-packages.yml`, depending on the `build-msi`
job. The Python SHA / URL / size are externalised so a Python security
patch can be rolled in without touching the .wxs.

## Verifying the embeddable

`PythonEmbed.wxs` declares the zip via a `RemotePayload` element. Burn
verifies the downloaded payload against the declared SHA-512 BEFORE
launching the install command. A mismatch aborts the chain - we never
unpack an unverified zip into Program Files.

Production CI MUST override the placeholder SHA-512 in
`PythonEmbed.wxs` via `-PythonZipSha512`. The placeholder is all zeros
so the file compiles but any actual chain run will fail until the SHA
is supplied. Compare with the `*.sha256` column on
<https://www.python.org/downloads/release/python-3119/> (use the
embeddable amd64 zip line).

## What's deferred

* **Custom WPF UI** - the current bundle uses the WiX standard
  HyperlinkLicense theme. A full 6-page custom UI (Welcome / EULA /
  PlatformURL / Token / Group / Install / Completion) is deferred to
  Phase 1E if customers ask for an attended-install experience.
* **Authenticode signing** - `-Sign` parameter is wired; cert
  procurement is a Phase 1E task.
* **Offline / air-gapped variant** - currently the embeddable is
  downloaded on demand. For air-gapped sites swap `RemotePayload` for
  an embedded `Payload SourceFile="python-3.11.9-embed-amd64.zip"`
  in PythonEmbed.wxs; the build script picks the file up out of
  `agent\packaging\windows\bootstrap\` next to the .wxs.
