#!/bin/bash
# Package the iOS build of Zero Hour into a signed .app and install it on a device.
#
# Flow:
#   1. xcodegen + xcodebuild produce a provisioning-shell app with automatic signing
#      (bundle id me.ammaar.generalszh, team 7S264298H8, Info.plist with file sharing).
#   2. The stub executable is replaced with the real z_generals engine binary.
#   3. Runtime dylibs (DXVK d3d8/d3d9, SDL3, SDL3_image) are embedded in Frameworks/
#      and their install names rewritten to @rpath.
#   4. Everything is re-signed inside-out with the Apple Development identity and the
#      provisioning profile from step 1, preserving entitlements.
#   5. Optional: install to the first connected device via devicectl.
#
# Usage: ./scripts/build/ios/package-ios-zh.sh [--dev] [--unsigned] [--ipa] [--install]
#   --dev        skip bundling retail game assets (code-only / shell iteration)
#   --unsigned   build and package without requiring an Apple Developer account
#   --ipa        create a packaged .ipa ready for sideloading in build/
#   --install    install the packaged app to the first connected device
set -euo pipefail

DEV_MODE=0
DO_INSTALL=0
UNSIGNED_MODE=0
DO_IPA=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev|--no-assets) DEV_MODE=1; shift ;;
        --unsigned)        UNSIGNED_MODE=1; shift ;;
        --ipa)             DO_IPA=1; shift ;;
        --install)         DO_INSTALL=1; shift ;;
        --bundle-id)       GX_BUNDLE_ID="$2"; shift 2 ;;
        --team-id)         GX_TEAM_ID="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1' (usage: $0 [--dev] [--unsigned] [--ipa] [--install])"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build/ios-vulkan"
IOS_DIR="${PROJECT_ROOT}/ios"
DERIVED="${IOS_DIR}/build"
OUT_DIR="${PROJECT_ROOT}/build/ios-package"
APP_NAME="GeneralsXZH"
IDENTITY="${GX_SIGN_IDENTITY:-Apple Development}"

# Signing/bundle identity — override for your own Apple Developer account:
#   GX_TEAM_ID=ABCDE12345 GX_BUNDLE_ID=com.you.generalszh ./package-ios-zh.sh --install
TEAM_ID="${GX_TEAM_ID:-}"
BUNDLE_ID="${GX_BUNDLE_ID:-com.cnc.generalszh}"

# Detect if running in CI or explicitly requested unsigned
if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" || "${GX_UNSIGNED:-}" == "1" ]]; then
    UNSIGNED_MODE=1
fi

GAME_BIN="${BUILD_DIR}/GeneralsMD/GeneralsXZH.app/GeneralsXZH"
if [[ ! -f "${GAME_BIN}" ]]; then
    if [[ -f "${BUILD_DIR}/GeneralsMD/GeneralsXZH" ]]; then
        GAME_BIN="${BUILD_DIR}/GeneralsMD/GeneralsXZH"
    elif [[ -f "${BUILD_DIR}/GeneralsMD/z_generals" ]]; then
        GAME_BIN="${BUILD_DIR}/GeneralsMD/z_generals"
    fi
fi
DXVK_BUILD="${BUILD_DIR}/_deps/dxvk-build-macos"

if [[ ! -f "${GAME_BIN}" ]]; then
    echo "ERROR: engine binary not found at ${GAME_BIN} — build the ios-vulkan preset first:"
    echo "  cmake --preset ios-vulkan && cmake --build build/ios-vulkan --target z_generals"
    exit 1
fi

echo "==> Generating Xcode project (xcodegen)"
(cd "${IOS_DIR}" && xcodegen generate --quiet)

if [[ "${UNSIGNED_MODE}" == "1" ]]; then
    echo "==> Building shell app (unsigned/ad-hoc mode)"
    xcodebuild -project "${IOS_DIR}/${APP_NAME}.xcodeproj" \
        -scheme "${APP_NAME}" -configuration Release \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "${DERIVED}" \
        PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        build | tail -3
else
    echo "==> Building provisioning shell app"
    XCODE_TEAM_ARG=()
    if [[ -n "${TEAM_ID}" ]]; then
        XCODE_TEAM_ARG=(DEVELOPMENT_TEAM="${TEAM_ID}")
    fi
    xcodebuild -project "${IOS_DIR}/${APP_NAME}.xcodeproj" \
        -scheme "${APP_NAME}" -configuration Release \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "${DERIVED}" \
        "${XCODE_TEAM_ARG[@]}" \
        PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
        -allowProvisioningUpdates build | tail -3 || {
            echo "⚠️ Provisioning build failed. Falling back to unsigned build..."
            UNSIGNED_MODE=1
            xcodebuild -project "${IOS_DIR}/${APP_NAME}.xcodeproj" \
                -scheme "${APP_NAME}" -configuration Release \
                -destination 'generic/platform=iOS' \
                -derivedDataPath "${DERIVED}" \
                PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
                CODE_SIGNING_ALLOWED=NO \
                CODE_SIGNING_REQUIRED=NO \
                CODE_SIGN_IDENTITY="" \
                build | tail -3
        }
fi

SHELL_APP="${DERIVED}/Build/Products/Release-iphoneos/${APP_NAME}.app"
if [[ ! -d "${SHELL_APP}" ]]; then
    echo "ERROR: shell app not produced at ${SHELL_APP}"
    exit 1
fi

echo "==> Assembling final app"
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
cp -R "${SHELL_APP}" "${OUT_DIR}/"
APP="${OUT_DIR}/${APP_NAME}.app"

# Replace stub executable with the engine
cp "${GAME_BIN}" "${APP}/${APP_NAME}"

# Embed runtime dylibs
mkdir -p "${APP}/Frameworks"
for lib in \
    "${DXVK_BUILD}/src/d3d8/libdxvk_d3d8.0.dylib" \
    "${DXVK_BUILD}/src/d3d9/libdxvk_d3d9.0.dylib" \
    "${BUILD_DIR}/_deps/sdl3-build/libSDL3.0.dylib" \
    "${BUILD_DIR}/_deps/sdl3_image-build/libSDL3_image.0.dylib" \
    "${BUILD_DIR}/_deps/openal_soft-build/libopenal.1.24.2.dylib" \
    "${BUILD_DIR}/libgamespy.dylib"; do
    if [[ -f "${lib}" ]]; then
        cp "${lib}" "${APP}/Frameworks/"
        echo "    embedded $(basename "${lib}")"
    else
        case "$(basename "${lib}")" in
            libgamespy.dylib)
                echo "    (skip, optional: $(basename "${lib}"))" ;;
            *)
                echo "ERROR: required dylib not built: ${lib}"
                echo "  Build first: cmake --preset ios-vulkan && cmake --build build/ios-vulkan --target z_generals"
                exit 1 ;;
        esac
    fi
done

# openal-soft's install name is libopenal.1.dylib; the embedded file must match it
if [[ -f "${APP}/Frameworks/libopenal.1.24.2.dylib" ]]; then
    mv "${APP}/Frameworks/libopenal.1.24.2.dylib" "${APP}/Frameworks/libopenal.1.dylib"
fi

# MoltenVK resolution: check local build first, then GX_MOLTENVK, then home directory
MVK_FRAMEWORK="${GX_MOLTENVK:-}"
if [[ -z "${MVK_FRAMEWORK}" || ! -d "${MVK_FRAMEWORK}" ]]; then
    for candidate in \
        "${PROJECT_ROOT}/build/MoltenVK/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework" \
        "${PROJECT_ROOT}/build/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework" \
        "${HOME}/GeneralsX/MoltenVK/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework" \
        "${HOME}/GeneralsX/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework"; do
        if [[ -d "${candidate}" ]]; then
            MVK_FRAMEWORK="${candidate}"
            break
        fi
    done
fi

if [[ -n "${MVK_FRAMEWORK}" && -d "${MVK_FRAMEWORK}" ]]; then
    cp -R "${MVK_FRAMEWORK}" "${APP}/Frameworks/"
    echo "    embedded MoltenVK.framework"
else
    echo "ERROR: MoltenVK.framework not found."
    echo "  Run scripts/build/ios/fetch-moltenvk.sh first to stage it."
    exit 1
fi

# Locate fonts and configuration
FONTS_SRC="${GX_FONTS:-}"
if [[ -z "${FONTS_SRC}" || ! -d "${FONTS_SRC}" ]]; then
    for candidate in \
        "${PROJECT_ROOT}/build/ios-staging/fonts" \
        "${PROJECT_ROOT}/assets/fonts" \
        "${HOME}/GeneralsX/ios-staging/fonts"; do
        if [[ -d "${candidate}" ]]; then
            FONTS_SRC="${candidate}"
            break
        fi
    done
fi
CONFIG_SRC="${GX_CONFIG:-${IOS_DIR}/config}"

# Always ensure fonts and base configuration exist in GameData (even in dev/shell mode)
mkdir -p "${APP}/GameData"
if [[ -n "${FONTS_SRC}" && -d "${FONTS_SRC}" ]]; then
    mkdir -p "${APP}/GameData/fonts"
    cp "${FONTS_SRC}"/*.ttf "${APP}/GameData/fonts/" 2>/dev/null || true
    echo "    bundled core fonts"
else
    echo "WARNING: core fonts not staged. The app may have missing text until fonts are supplied."
    echo "  Run scripts/build/ios/stage-fonts.sh to download Liberation fonts."
fi

for cfg in dxvk.conf Options.ini; do
    if [[ -f "${CONFIG_SRC}/${cfg}" ]]; then
        if [[ "${cfg}" == "Options.ini" ]]; then
            cp "${CONFIG_SRC}/${cfg}" "${APP}/GameData/DefaultOptions.ini"
        else
            cp "${CONFIG_SRC}/${cfg}" "${APP}/GameData/${cfg}"
        fi
    fi
done

# Game assets inside the bundle:
# When not in --dev mode, copy retail game data if provided
GAME_DATA_SRC="${GX_GAME_DATA:-}"
if [[ -z "${GAME_DATA_SRC}" || ! -d "${GAME_DATA_SRC}" ]]; then
    for candidate in \
        "${PROJECT_ROOT}/gameres-export" \
        "${HOME}/GeneralsX/GeneralsZH"; do
        if [[ -d "${candidate}" ]]; then
            GAME_DATA_SRC="${candidate}"
            break
        fi
    done
fi

if [[ "${DEV_MODE}" != "1" && -n "${GAME_DATA_SRC}" && -d "${GAME_DATA_SRC}" ]]; then
    echo "==> Bundling retail game assets from ${GAME_DATA_SRC} into the app"
    rsync -a --exclude=".*" \
        --exclude="*.dylib" --exclude="run.sh" --exclude="GeneralsXZH" \
        --exclude="GeneralsXZH.dxvk-cache" --exclude="*_d3d9.log" \
        --exclude="MoltenVK_icd.json" --exclude="dxvk.conf" --exclude="fontconfig" \
        --exclude="*.DLL" --exclude="*.dll" --exclude="*.dat" --exclude="*.ico" \
        --exclude="*.bmp" --exclude="*.doc" --exclude="*.lcf" --exclude="Launcher.txt" \
        --exclude="MSS" --exclude="Manuals" --exclude="steamapps" \
        --exclude="steam_appid.txt" --exclude="00000000.*" \
        --exclude="RedistInstallers" --exclude="_CommonRedist" --exclude="*.txt" \
        "${GAME_DATA_SRC}/" "${APP}/GameData/"
    echo "    bundled $(du -sh "${APP}/GameData" | cut -f1) of game data"
else
    echo "==> Lightweight Shell Mode: retail game assets not bundled."
    echo "    Game assets will be loaded from Documents or injected via inject-gameres scripts."
fi

# Loose icon PNGs alongside the compiled asset catalog
ICON_SRC="${IOS_DIR}/Stub/Assets.xcassets/AppIcon.appiconset/icon.png"
if [[ -f "${ICON_SRC}" ]] && command -v sips &>/dev/null; then
    sips -z 120 120 "${ICON_SRC}" --out "${APP}/AppIcon60x60@2x.png"  >/dev/null 2>&1 || true
    sips -z 152 152 "${ICON_SRC}" --out "${APP}/AppIcon76x76@2x.png"  >/dev/null 2>&1 || true
    sips -z 167 167 "${ICON_SRC}" --out "${APP}/AppIcon83.5x83.5@2x.png" >/dev/null 2>&1 || true
    echo "    icon PNG fallbacks added"
fi

# Point the executable's rpath at the embedded frameworks
install_name_tool -add_rpath "@executable_path/Frameworks" "${APP}/${APP_NAME}" 2>/dev/null || true

# Code signing
if [[ "${UNSIGNED_MODE}" == "1" ]]; then
    echo "==> Signing app ad-hoc (sideloadable)"
    for f in "${APP}/Frameworks/"*.dylib; do
        [[ -f "$f" ]] && codesign --force --sign - --timestamp=none "$f" 2>/dev/null || true
    done
    if [[ -d "${APP}/Frameworks/MoltenVK.framework" ]]; then
        codesign --force --sign - --timestamp=none "${APP}/Frameworks/MoltenVK.framework" 2>/dev/null || true
    fi
    codesign --force --sign - --timestamp=none "${APP}" 2>/dev/null || true
    echo "    ad-hoc signature applied"
else
    echo "==> Re-signing with developer certificate (${IDENTITY})"
    ENTITLEMENTS="${OUT_DIR}/entitlements.plist"
    codesign -d --entitlements - --xml "${SHELL_APP}" > "${ENTITLEMENTS}" 2>/dev/null || true

    for f in "${APP}/Frameworks/"*.dylib; do
        [[ -f "$f" ]] && codesign --force --sign "${IDENTITY}" --timestamp=none "$f"
    done
    if [[ -d "${APP}/Frameworks/MoltenVK.framework" ]]; then
        codesign --force --sign "${IDENTITY}" --timestamp=none "${APP}/Frameworks/MoltenVK.framework"
    fi
    if [[ -f "${ENTITLEMENTS}" && -s "${ENTITLEMENTS}" ]]; then
        codesign --force --sign "${IDENTITY}" --timestamp=none \
            --entitlements "${ENTITLEMENTS}" "${APP}"
    else
        codesign --force --sign "${IDENTITY}" --timestamp=none "${APP}"
    fi
    codesign --verify --deep "${APP}" && echo "    signature OK"
fi

echo "==> App ready: ${APP}"

# IPA Packaging
if [[ "${DO_IPA}" == "1" ]]; then
    echo "==> Packaging into IPA..."
    mkdir -p "${PROJECT_ROOT}/build"
    PAYLOAD_DIR="${OUT_DIR}/Payload"
    rm -rf "${PAYLOAD_DIR}"
    mkdir -p "${PAYLOAD_DIR}"
    cp -R "${APP}" "${PAYLOAD_DIR}/"
    
    IPA_NAME="${APP_NAME}.ipa"
    if [[ "${UNSIGNED_MODE}" == "1" ]]; then
        IPA_NAME="${APP_NAME}-unsigned.ipa"
    fi
    IPA_PATH="${PROJECT_ROOT}/build/${IPA_NAME}"
    rm -f "${IPA_PATH}"
    
    (cd "${OUT_DIR}" && zip -r -q "${IPA_PATH}" Payload)
    echo "==> SUCCESS: Created IPA at ${IPA_PATH} ($(du -sh "${IPA_PATH}" | cut -f1))"
fi

if [[ "${DO_INSTALL}" == "1" ]]; then
    echo "==> Installing to connected device"
    DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | awk '/connected/{print $(NF-2); exit}')
    if [[ -z "${DEVICE_ID}" ]]; then
        DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | grep -i connected | grep -oE '[0-9A-F-]{36}' | head -1)
    fi
    if [[ -z "${DEVICE_ID}" ]]; then
        echo "ERROR: no connected device found (xcrun devicectl list devices)"
        exit 1
    fi
    xcrun devicectl device install app --device "${DEVICE_ID}" "${APP}"
    echo "==> Installed successfully."
fi
