@echo off
REM NethraOps Agent - silent install wrapper.
REM
REM Usage:
REM   install.cmd <CLAIM_TOKEN> <PLATFORM_URL> [DEVICE_GROUP] [HOST_LABEL]
REM
REM Examples:
REM   install.cmd ACMECLAIM-abc123 https://monitor.acme.com
REM   install.cmd ACMECLAIM-abc123 https://monitor.acme.com prod-east db-east-01
REM
REM Exit codes:
REM   0    OK (or 3010 reboot recommended, treated as OK)
REM   1    Bad arguments
REM   *    msiexec exit code (see %TEMP%\nethraops-install.log)
REM
REM ASCII only - this file is bundled into the .intunewin and dropped on
REM the target host as-is.

setlocal EnableExtensions EnableDelayedExpansion

set "CLAIM=%~1"
set "URL=%~2"
set "GROUP=%~3"
set "LABEL=%~4"

if "%CLAIM%"=="" goto :usage
if "%URL%"=="" goto :usage

set "HERE=%~dp0"
set "MSI=%HERE%..\dist\NethraOpsMonitorAgent.msi"
if not exist "%MSI%" (
    REM Fall back to whatever versioned MSI is present in dist\.
    for /f "delims=" %%F in ('dir /b /od "%HERE%..\dist\NethraOpsMonitorAgent-*.msi" 2^>nul') do set "MSI=%HERE%..\dist\%%F"
)

if not exist "%MSI%" (
    echo ERROR: no MSI found in %HERE%..\dist\. Build first with build.ps1. 1>&2
    exit /b 1
)

set "LOG=%TEMP%\nethraops-install.log"
echo [nethraops-install] msi=%MSI%
echo [nethraops-install] log=%LOG%

msiexec /i "%MSI%" /qn /l*v "%LOG%" ^
    CLAIM_TOKEN="%CLAIM%" ^
    PLATFORM_URL="%URL%" ^
    DEVICE_GROUP="%GROUP%" ^
    HOST_LABEL="%LABEL%"
set RC=%ERRORLEVEL%

if "%RC%"=="0" (
    echo [nethraops-install] OK
    exit /b 0
)
if "%RC%"=="3010" (
    echo [nethraops-install] OK - reboot recommended
    exit /b 0
)
echo [nethraops-install] FAILED with msiexec exit code %RC%. See %LOG%. 1>&2
exit /b %RC%

:usage
echo Usage: install.cmd CLAIM_TOKEN PLATFORM_URL [DEVICE_GROUP] [HOST_LABEL] 1>&2
exit /b 1
