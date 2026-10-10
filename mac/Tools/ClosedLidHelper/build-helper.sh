#!/bin/bash
set -euo pipefail

helper_source="${SRCROOT:?}/Tools/ClosedLidHelper/main.swift"
helper_destination="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers/androp-closed-lid-helper"
helper_work="${DERIVED_FILE_DIR:?}/androp-closed-lid-helper"
helper_sdk="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
helper_deployment="${MACOSX_DEPLOYMENT_TARGET:-14.5}"
mkdir -p "$helper_work" "$(dirname "$helper_destination")"

helper_architectures="${ARCHS:-${CURRENT_ARCH:-arm64}}"
helper_outputs=()
for helper_arch in $helper_architectures; do
    case "$helper_arch" in arm64|x86_64) ;; *) echo "Unsupported helper architecture: $helper_arch" >&2; exit 1 ;; esac
    helper_binary="$helper_work/helper-$helper_arch"
    /usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -O \
        -sdk "$helper_sdk" -target "$helper_arch-apple-macos$helper_deployment" \
        -module-cache-path "$helper_work/module-cache" \
        -framework Foundation -framework IOKit "$helper_source" -o "$helper_binary"
    helper_outputs+=("$helper_binary")
done
if [ "${#helper_outputs[@]}" -gt 1 ]; then
    /usr/bin/xcrun lipo -create "${helper_outputs[@]}" -output "$helper_destination"
else
    /bin/cp "${helper_outputs[0]}" "$helper_destination"
fi
/bin/chmod 755 "$helper_destination"

# Sign nested executable before Xcode signs its enclosing application bundle.
# Ad-hoc signing permits local/private Debug builds without an admin installer.
helper_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ -z "$helper_identity" ]; then helper_identity="-"; fi
if [ "$helper_identity" = "-" ]; then
    /usr/bin/codesign --force --sign - "$helper_destination"
else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$helper_identity" "$helper_destination"
fi
