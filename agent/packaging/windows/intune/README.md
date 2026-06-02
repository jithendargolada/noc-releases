# Intune deployment

Operator playbook for shipping the NethraOps Agent through Microsoft
Intune as a Win32 LOB app.

## Prerequisites

- An MSI built from `agent/packaging/windows/msi/` (see `docs/windows-installer/BUILD.md`).
- The Microsoft Win32 Content Prep Tool (`IntuneWinAppUtil.exe`). Download
  from <https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool>.
- Intune RBAC: at minimum the *Application Manager* role.
- The customer's claim token (one per host or one per rollout - both work,
  as long as the TTL covers the rollout window).

## 1. Build the .intunewin

Run on the same Windows box you used to build the MSI:

```
cd agent\packaging\windows\intune
.\build-intunewin.ps1
```

The script stages `install.cmd`, `uninstall.cmd`, `upgrade.cmd`,
`repair.cmd`, `detection.ps1`, and the MSI itself into a temp folder,
then calls `IntuneWinAppUtil.exe -c <folder> -s install.cmd -o dist\`.
Output: `agent\packaging\windows\intune\dist\NethraOpsMonitorAgent-<ver>.intunewin`.

## 2. Upload to Intune

In the Intune admin centre:

1. **Apps -> Windows -> Add -> App type: Windows app (Win32)**.
2. **App package file** -> upload the `.intunewin`.
3. **App information** -> Name `NethraOps Agent`, Publisher `NethraOps`,
   leave the rest as defaults.

## 3. Install / uninstall commands

The values below are the exact strings to paste into Intune. The
`CLAIM_TOKEN` and `PLATFORM_URL` are the operator-supplied secrets - you
will need a per-rollout claim with a TTL long enough to cover the
deployment window (issue it from the Windows Deployment Center UI in the
backend).

| Field | Value |
| --- | --- |
| Install command | `install.cmd YOUR_CLAIM_TOKEN https://monitor.acme.com` |
| Uninstall command | `uninstall.cmd` |
| Install behavior | System |
| Device restart behavior | App install may force a device restart |
| Allowed exit codes | 0 (success), 3010 (soft reboot) |

For an in-place repair: `repair.cmd`.

## 4. Detection rule

Use the bundled PowerShell detection script - it returns exit 0 when both
the NethraOpsAgent service exists AND the MSI UpgradeCode is registered.

1. Detection rules -> **Rules format: Use a custom detection script**.
2. Upload `detection.ps1` (it is staged into the .intunewin under the
   setup folder).
3. **Run script as 32-bit process on 64-bit clients**: No.
4. **Enforce script signature check**: No (or Yes if your tenant signs
   helper scripts).

Alternative MSI-product-code detection (no script): use the MSI product
code emitted by `build.ps1`. The product code is regenerated each build
(WiX `Id="*"`), so this only works for a single-version rollout - the
script is the better long-term choice.

## 5. Assignments

Assign to a device group. The agent runs as `LocalSystem`, so user
assignment is not meaningful - it will install but the per-user
configuration on the device is the same as the per-device install.

## 6. Verifying a rollout

On a target device:

```powershell
Get-Service NethraOpsAgent
Get-Content 'C:\ProgramData\NethraOpsAgent\agent.env'
Get-Content 'C:\ProgramData\NethraOpsAgent\state.json'
Get-WinEvent -LogName Application -ProviderName 'Python Service Manager' -MaxEvents 20
```

The Intune install log lives at
`C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log`.
The MSI log lives at `%TEMP%\nethraops-install.log` for the SYSTEM user
(typically `C:\Windows\Temp\nethraops-install.log` for Intune runs).

## 7. Known issues

- **CLAIM_TOKEN expiry mid-rollout.** A claim is single-use. If you
  assign the same .intunewin to N devices it will consume N claims if
  each gets a fresh token - which means you cannot reuse a single claim
  across devices. Today the recommended pattern is to either (a) issue
  a long-TTL claim and accept that the first device to install wins, or
  (b) wait for Phase 1C, which introduces device-group claims with a
  configurable use count. The Intune install will fail with `HTTP 410`
  on every device after the first if you reuse a single-use claim.
- **No code signing yet.** The MSI is unsigned. Tenants that enforce
  *Enforce signature check* on Win32 apps will reject the package. Sign
  on Windows in CI with `signtool.exe` once a cert is provisioned (see
  `agent/packaging/windows/msi/build.ps1 -Sign`).
