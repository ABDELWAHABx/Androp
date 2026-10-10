#!/usr/bin/env bash
set -euo pipefail

release_tag="${1:?Usage: build-mac.sh <release-tag> [arm64|universal]}"
release_architecture="${2:-arm64}"
if [[ ! "$release_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]]; then
    echo "Use a release tag with 1–80 letters, digits, dots, underscores or hyphens." >&2
    exit 2
fi
case "$release_architecture" in
    arm64) release_archs="arm64" ;;
    universal) release_archs="arm64 x86_64" ;;
    *) echo "Architecture must be arm64 or universal." >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
    echo "This script requires macOS with Xcode 26+ and Swift 6.2+." >&2
    exit 2
fi
release_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
release_dist="$release_root/dist"
release_work=$(mktemp -d "${TMPDIR:-/tmp}/androp-release.XXXXXX")
trap 'rm -rf "$release_work"' EXIT
mkdir -p "$release_dist"
release_name="androp-${release_tag}-${release_architecture}"
release_stage="$release_work/$release_name"
release_derived="$release_work/DerivedData"
mkdir -p "$release_stage"

python3 - <<'PY'
import re, subprocess
for command, minimum in [(['xcodebuild','-version'], (26,)), (['xcrun','swiftc','--version'], (6,2))]:
    output=subprocess.check_output(command,text=True)
    print(output.strip())
    match=re.search(r'(?:Xcode|Swift version)\s+(\d+)(?:\.(\d+))?',output)
    version=tuple(int(x or 0) for x in match.groups()) if match else ()
    if version < minimum:
        raise SystemExit('Xcode 26+ / Swift 6.2+ is required.')
PY
# This pure policy harness does not enable assertions or private driver behavior.
bash "$release_root/Tests/run-mac-power-policy-tests.sh"

# Ad-hoc signing avoids a certificate/provisioning secret. Plugin/macro validation
# is bypassed only for the repository's resolved dependencies on this private CI.
xcodebuild build \
    -project "$release_root/AirSync.xcodeproj" -scheme androp \
    -configuration 'Self Compiled' -destination 'generic/platform=macOS' \
    -derivedDataPath "$release_derived" \
    -skipPackagePluginValidation -skipMacroValidation \
    ARCHS="$release_archs" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    2>&1 | tee "$release_dist/build.log"

release_built_app="$release_derived/Build/Products/Self Compiled/androp.app"
test -d "$release_built_app"
ditto "$release_built_app" "$release_stage/androp.app"
release_app="$release_stage/androp.app"
release_widget="$release_app/Contents/PlugIns/andropWidget.appex"
release_helper="$release_app/Contents/Helpers/androp-closed-lid-helper"
test -d "$release_widget"
test -x "$release_helper"

# Xcode signs embedded frameworks using the same manual identity. Re-sign these
# explicit bundles inside-out, preserving Xcode-generated sandbox/group metadata.
codesign --force --sign - --timestamp=none "$release_helper"
codesign --force --sign - --timestamp=none --preserve-metadata=entitlements,flags,runtime "$release_widget"
codesign --force --sign - --timestamp=none --preserve-metadata=entitlements,flags,runtime "$release_app"
codesign --verify --deep --strict --verbose=2 "$release_app"
codesign --verify --strict "$release_helper"
codesign --verify --strict "$release_widget"

python3 - "$release_app" "$release_architecture" <<'PY'
import plistlib, subprocess, sys
from pathlib import Path
app=Path(sys.argv[1]); requested=sys.argv[2]
for bundle,identifier,maximum in [(app,'app.androp.mac',(14,5)),
    (app/'Contents/PlugIns/andropWidget.appex','app.androp.mac.widget',(15,0))]:
    metadata=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    assert metadata['CFBundleIdentifier']==identifier, metadata
    minimum=tuple(int(x) for x in metadata['LSMinimumSystemVersion'].split('.')[:2])
    assert minimum <= maximum, (identifier,minimum)
    executable=bundle/'Contents/MacOS'/metadata['CFBundleExecutable']
    architectures=subprocess.check_output(['lipo','-archs',str(executable)],text=True).split()
    assert 'arm64' in architectures, architectures
    if requested=='universal': assert 'x86_64' in architectures, architectures
print('Verified bundle identities, deployment versions and requested architectures.')
PY

cp "$release_root/LICENSE" "$release_stage/LICENSE"
cp "$release_root/README.upstream.md" "$release_stage/README.upstream.md"
python3 - "$release_derived/SourcePackages/checkouts" "$release_stage/ThirdPartyNotices" <<'PY'
import shutil,sys
from pathlib import Path
source=Path(sys.argv[1]); destination=Path(sys.argv[2])
if source.exists():
    for package in source.iterdir():
        if not package.is_dir(): continue
        for notice in package.iterdir():
            if notice.is_file() and notice.name.upper().startswith(('LICENSE','COPYING','NOTICE','AUTHORS')):
                target=destination/package.name/notice.name
                target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(notice,target)
PY
cat > "$release_stage/INSTALL.txt" <<'EOF'
Drag androp.app to Applications, then open it.
This private build is ad-hoc signed and is not Apple notarized. macOS may require
an explicit Open Anyway in Privacy & Security before it will launch.

The app supports macOS 14.5+; its bundled widget requires macOS 15+.
Widget app-group access with an ad-hoc signature may require a developer-signed
local build. Pair with the matching private androp Android application.

Experimental closed-lid mode is OFF by default and must be enabled locally.
It uses a private macOS 15 driver interface with a bounded watchdog. Acceptance
is not proof of physical closed-lid behavior; hardware testing remains required.
The driver setting is shared with macOS/other apps. Keep the Mac in reach and
avoid heat buildup in a bag. No daemon, admin installation or pmset change runs.

Source, attribution and original license are available in this private repository.
EOF
release_commit=$(git -C "$release_root" rev-parse HEAD)
python3 - "$release_stage/BUILD.json" "$release_tag" "$release_commit" "$release_architecture" <<'PY'
import json,subprocess,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps(dict(tag=sys.argv[2],commit=sys.argv[3],
    architecture=sys.argv[4],signing='ad-hoc',notarized=False,
    appMinimumMacOS='14.5',widgetMinimumMacOS='15.0',
    xcode=subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
    experimentalClosedLidDefault=False),indent=2)+'\n')
PY
ln -s /Applications "$release_stage/Applications"
ditto -c -k --sequesterRsrc --keepParent "$release_stage" "$release_dist/$release_name.zip"
hdiutil create -volname androp -srcfolder "$release_stage" -format UDZO -ov "$release_dist/$release_name.dmg"
cp "$release_stage/BUILD.json" "$release_dist/$release_name-BUILD.json"
(
    cd "$release_dist"
    shasum -a 256 "$release_name.zip" "$release_name.dmg" "$release_name-BUILD.json" > "$release_name-SHA256SUMS.txt"
)
echo "Packaged $release_dist/$release_name.zip and .dmg"
