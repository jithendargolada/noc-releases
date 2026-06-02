@echo off
REM NethraOps Agent - in-place upgrade wrapper.
REM
REM Standard Windows Installer upgrade dance: drop a higher-version MSI
REM next to this script (or pass its path), then run the same
REM `msiexec /i` invocation with REINSTALLMODE=amus. The MajorUpgrade
REM element in Product.wxs (Schedule="afterInstallExecute") handles
REM removing the old install AFTER the new files land, so the data
REM directory in C:\ProgramData\NethraOpsAgent survives the upgrade and
REM agent.env + state.json (with the saved agent_token) are preserved.
REM
REM Usage:
REM   upgrade.cmd                            -> auto-finds the newest .msi in ..\dist
REM   upgrade.cmd <path-to-newer-msi>
REM
REM This script does NOT take a CLAIM_TOKEN argument - upgrades reuse
REM the existing registration in state.json. If you need to re-enrol the
REM host against a different backend or tenant, uninstall first
REM (uninstall.cmd) and then install fresh.

setlocal EnableExtensions EnableDelayedExpansion

set "HERE=%~dp0"
set "MSI=%~1"
if "%MSI%"=="" (
    for /f "delims=" %%F in ('dir /b /od "%HERE%..\dist\NethraOpsMonitorAgent-*.msi" 2^>nul') do set "MSI=%HERE%..\dist\%%F"
)

if "%MSI%"=="" (
    echo ERROR: no MSI specified and none found in ..\dist\. 1>&2
    exit /b 1
)
if not exist "%MSI%" (
    echo ERROR: MSI not found at %MSI%. 1>&2
    exit /b 1
)

set "LOG=%TEMP%\nethraops-upgrade.log"
echo [nethraops-upgrade] msi=%MSI%
echo [nethraops-upgrade] log=%LOG%

msiexec /i "%MSI%" /qn /l*v "%LOG%" REINSTALLMODE=amus
set RC=%ERRORLEVEL%

if "%RC%"=="0"   ( echo [nethraops-upgrade] OK & exit /b 0 )
if "%RC%"=="3010" ( echo [nethraops-upgrade] OK - reboot recommended & exit /b 0 )
echo [nethraops-upgrade] FAILED with msiexec exit code %RC%. See %LOG%. 1>&2
exit /b %RC%
