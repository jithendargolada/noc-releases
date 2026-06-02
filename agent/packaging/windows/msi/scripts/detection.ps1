# Intune detection script for the NethraOps Agent.
#
# Intune treats stdout + exit 0 as "installed", exit 1 as "not installed".
# We assert two things:
#   1. The NethraOpsAgent Windows service exists.
#   2. The MSI UpgradeCode registry entry exists (i.e. the MSI - not just
#      a manual venv copy - is what put the service there).

$ErrorActionPreference = 'SilentlyContinue'
$svc = Get-Service -Name 'NethraOpsAgent'
if (-not $svc) { exit 1 }

# Reverse-byte form of UpgradeCode 615C305A-EAE6-4DFA-ABC9-6DA856100191.
$key = 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes\A503C516-6EAE-AFD4-CB9A-E68A65010019'
if (-not (Test-Path $key)) { exit 1 }

Write-Output "NethraOpsAgent installed, service status: $($svc.Status)"
exit 0
