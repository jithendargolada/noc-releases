#!/usr/bin/env bash
# Linux fallback: build the NethraOps Agent MSI with wixl (the
# msitools project, https://wiki.gnome.org/msitools).
#
# Limitations vs the Windows build:
#   - No WixUI_Minimal (wixl ignores UI extensions). Result is a fully
#     silent installer suitable for /qn only.
#   - No signtool. Code signing must happen on Windows in CI.
#   - WixUtilExtension is not available, so the ACL on DATADIR is not
#     applied at install time - the agent installer (Install-NethraOpsAgent.ps1)
#     re-applies it on first start.
#   - Custom actions still reference WixCA, which wixl does not ship.
#     We emit a stripped Product.wxs for the wixl build that skips the
#     CA references; the resulting MSI only stages files + registers the
#     uninstall entry. Operators must run Install-NethraOpsAgent.ps1
#     manually after install - useful for smoke-testing the MSI shape
#     without a Windows build box, NOT a production replacement.
#
# Usage:
#   ./build-wixl.sh [VERSION]
# Output:
#   ./dist/NethraOpsMonitorAgent-<version>.msi
#   ./dist/NethraOpsMonitorAgent-<version>.msi.sha256
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$HERE/dist"
BUILD="$HERE/build"
mkdir -p "$DIST" "$BUILD"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    if [[ -f "$DIST/VERSION" ]]; then
        VERSION="$(head -n1 "$DIST/VERSION" | tr -d '[:space:]')"
    else
        VERSION="0.1.0"
    fi
fi

if ! command -v wixl >/dev/null 2>&1; then
    echo "wixl not found. Install msitools (Debian/Ubuntu: apt install wixl)." >&2
    echo "Or run build.ps1 on a Windows host with WiX Toolset installed." >&2
    exit 1
fi

# Build a stripped Product.wxs for wixl - drop the WixUI/Util references
# wixl cannot handle.
STRIPPED="$BUILD/Product.wixl.wxs"
python3 - "$HERE/Product.wxs" "$STRIPPED" "$VERSION" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
# Drop the WixUI ref + the WixVariable + the util:PermissionEx blocks.
src = re.sub(r'<UIRef[^/]*/>', '', src)
src = re.sub(r'<WixVariable[^/]*/>', '', src)
src = re.sub(r'<util:PermissionEx[^/]*/>', '', src)
# Drop the CustomActionRefs - wixl will not have them defined.
src = re.sub(r'<CustomActionRef[^/]*/>', '', src)
# Drop the entire InstallExecuteSequence custom-action block.
src = re.sub(
    r'<InstallExecuteSequence>.*?</InstallExecuteSequence>',
    '<InstallExecuteSequence />',
    src,
    flags=re.S,
)
src = src.replace('$(var.ProductVersion)', sys.argv[3])
src = src.replace('$(var.ProductName)', 'NethraOps Agent')
src = src.replace('$(var.ProductShortName)', 'NethraOpsAgent')
src = src.replace('$(var.Manufacturer)', 'NethraOps')
src = src.replace('$(var.UpgradeCode)', '615C305A-EAE6-4DFA-ABC9-6DA856100191')
src = src.replace('$(var.InstallDirName)', 'NethraOpsAgent')
src = src.replace('$(var.DataDirName)', 'NethraOpsAgent')
# Drop the <?include?> and the Icon ref (we have no .ico bundled here).
src = re.sub(r'<\?include[^?]*\?>', '', src)
src = re.sub(r'<Icon[^/]*/>', '', src)
src = re.sub(r'<Property\s+Id="ARPPRODUCTICON"[^/]*/>', '', src)
open(sys.argv[2], 'w').write(src)
PY

OUT="$DIST/NethraOpsMonitorAgent-$VERSION.msi"
echo "[nethraops-build] wixl -> $OUT"
wixl -v -o "$OUT" "$STRIPPED"

if [[ ! -f "$OUT" ]]; then
    echo "wixl did not produce $OUT" >&2
    exit 1
fi

HASH="$(sha256sum "$OUT" | awk '{print $1}')"
echo "$HASH" > "$OUT.sha256"
echo "$VERSION" > "$DIST/VERSION"

echo ""
echo "[nethraops-build] OK"
echo "  MSI    : $OUT"
echo "  SHA256 : $HASH"
echo "  Version: $VERSION"
echo ""
echo "NOTE: wixl builds are file-staging only - custom actions are"
echo "stripped. Use build.ps1 on a Windows host with WiX Toolset for a"
echo "production MSI."
