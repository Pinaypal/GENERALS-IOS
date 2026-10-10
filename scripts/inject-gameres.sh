#!/usr/bin/env bash
# Injects local Command & Conquer Generals Zero Hour retail game assets into the iOS Shell IPA on macOS / Linux.
#
# Usage:
#   ./scripts/inject-gameres.sh                                  # auto-detects paths
#   ./scripts/inject-gameres.sh "/path/to/Zero Hour"             # with explicit game directory
#   ./scripts/inject-gameres.sh "/path/to/Zero Hour" "shell.ipa" "final.ipa"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

echo "=========================================================="
echo " Command & Conquer Generals: Zero Hour iOS Asset Injector "
echo "=========================================================="

GAME_DIR="${1:-}"
IPA_PATH="${2:-GeneralsXZH-unsigned.ipa}"
OUTPUT_PATH="${3:-GeneralsXZH-ready-to-sideload.ipa}"

# 1. Resolve IPA
if [[ ! -f "${IPA_PATH}" ]]; then
    for cand in \
        "${PROJECT_ROOT}/${IPA_PATH}" \
        "${PROJECT_ROOT}/build/${IPA_PATH}" \
        "${PROJECT_ROOT}/GeneralsXZH-unsigned.ipa" \
        "${PROJECT_ROOT}/build/GeneralsXZH-unsigned.ipa" \
        "${PROJECT_ROOT}/GeneralsXZH.ipa"; do
        if [[ -f "${cand}" ]]; then
            IPA_PATH="${cand}"
            break
        fi
    done
fi

if [[ ! -f "${IPA_PATH}" ]]; then
    echo "ERROR: Could not find iOS IPA at '${IPA_PATH}'."
    echo "Download 'GeneralsXZH-unsigned.ipa' from GitHub Actions and place it in the project root."
    exit 1
fi

echo "--> Shell IPA: ${IPA_PATH}"

# 2. Resolve Game Directory
if [[ -z "${GAME_DIR}" ]]; then
    if [[ -d "${PROJECT_ROOT}/gameres-export" && -f "${PROJECT_ROOT}/gameres-export/INIZH.big" ]]; then
        GAME_DIR="${PROJECT_ROOT}/gameres-export"
    fi
fi

if [[ -z "${GAME_DIR}" ]]; then
    SEARCH_CANDIDATES=(
        "${HOME}/Library/Application Support/Steam/steamapps/common/Command & Conquer Generals - Zero Hour"
        "${HOME}/Library/Application Support/Steam/steamapps/common/Command and Conquer Generals Zero Hour"
        "${HOME}/.steam/steam/steamapps/common/Command & Conquer Generals - Zero Hour"
        "${HOME}/.local/share/Steam/steamapps/common/Command & Conquer Generals - Zero Hour"
        "${HOME}/GeneralsX/GeneralsZH"
    )
    for cand in "${SEARCH_CANDIDATES[@]}"; do
        if [[ -d "${cand}" ]]; then
            # case-insensitive search for INIZH.big
            if find "${cand}" -maxdepth 1 -iname "*INIZH.big" | grep -q .; then
                GAME_DIR="${cand}"
                break
            fi
        fi
    done
fi

if [[ -z "${GAME_DIR}" || ! -d "${GAME_DIR}" ]]; then
    echo ""
    echo "Could not auto-detect retail Zero Hour directory."
    read -r -p "Enter path to Zero Hour install folder: " GAME_DIR
fi

if [[ -z "${GAME_DIR}" || ! -d "${GAME_DIR}" ]]; then
    echo "ERROR: Invalid game directory: '${GAME_DIR}'"
    exit 1
fi

echo "--> Retail Game Source: ${GAME_DIR}"

# 3. Verify core files
if ! find "${GAME_DIR}" -maxdepth 1 -iname "*INIZH.big" | grep -q .; then
    echo "ERROR: Could not find INIZH.big in '${GAME_DIR}'."
    exit 1
fi

TEMP_DIR="$(mktemp -d -t generals_inject_XXXXXX)"
cleanup() {
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

echo "==> [1/4] Extracting Shell IPA (${IPA_PATH})..."
unzip -q "${IPA_PATH}" -d "${TEMP_DIR}"

APP_DIR="$(find "${TEMP_DIR}/Payload" -mindepth 1 -maxdepth 1 -name "*.app" | head -1)"
if [[ -z "${APP_DIR}" || ! -d "${APP_DIR}" ]]; then
    echo "ERROR: Invalid IPA: No .app directory found inside Payload/"
    exit 1
fi

TARGET_GAMEDATA="${APP_DIR}/GameData"
mkdir -p "${TARGET_GAMEDATA}"

echo "==> [2/4] Injecting retail game assets from: ${GAME_DIR}..."

# Copy all .big files from root
find "${GAME_DIR}" -maxdepth 1 -iname "*.big" -exec cp {} "${TARGET_GAMEDATA}/" \;

# Copy Data, Maps, Window, Movies directories if present
for sub in Data Maps Window Movies; do
    SUB_SRC="$(find "${GAME_DIR}" -maxdepth 1 -iname "${sub}" | head -1)"
    if [[ -n "${SUB_SRC}" && -d "${SUB_SRC}" ]]; then
        echo "    + Copying ${sub}..."
        cp -R "${SUB_SRC}" "${TARGET_GAMEDATA}/"
    fi
done

# Copy base game folder (ZH_Generals)
ZH_GEN_DIR="$(find "${GAME_DIR}" -maxdepth 1 -iname "ZH_Generals" | head -1)"
if [[ -n "${ZH_GEN_DIR}" && -d "${ZH_GEN_DIR}" ]]; then
    echo "    + Copying base game data (ZH_Generals)..."
    cp -R "${ZH_GEN_DIR}" "${TARGET_GAMEDATA}/"
else
    # Check parent directory for base game
    PARENT="$(dirname "${GAME_DIR}")"
    for cand in "${PARENT}/Command & Conquer Generals" "${PARENT}/Command and Conquer Generals" "${PARENT}/Generals"; do
        if [[ -d "${cand}" ]] && find "${cand}" -maxdepth 1 -iname "INI.big" | grep -q .; then
            echo "    + Found base game at: ${cand}. Staging ZH_Generals..."
            DEST_ZH="${TARGET_GAMEDATA}/ZH_Generals"
            mkdir -p "${DEST_ZH}"
            find "${cand}" -maxdepth 1 -iname "*.big" -exec cp {} "${DEST_ZH}/" \;
            for d in Data Maps Window; do
                if [[ -d "${cand}/${d}" ]]; then cp -R "${cand}/${d}" "${DEST_ZH}/"; fi
            done
            break
        fi
    done
fi

# Ensure fonts exist
mkdir -p "${TARGET_GAMEDATA}/fonts"
if [[ ! -f "${TARGET_GAMEDATA}/fonts/arial.ttf" ]]; then
    echo "    + Staging core fonts..."
    "${SCRIPT_DIR}/build/ios/stage-fonts.sh" 2>/dev/null || true
    if [[ -d "${PROJECT_ROOT}/build/ios-staging/fonts" ]]; then
        cp "${PROJECT_ROOT}/build/ios-staging/fonts"/*.ttf "${TARGET_GAMEDATA}/fonts/" 2>/dev/null || true
    fi
fi

# Ensure configuration files exist
if [[ -f "${PROJECT_ROOT}/ios/config/dxvk.conf" ]]; then
    cp "${PROJECT_ROOT}/ios/config/dxvk.conf" "${TARGET_GAMEDATA}/dxvk.conf"
fi
if [[ -f "${PROJECT_ROOT}/ios/config/Options.ini" ]]; then
    cp "${PROJECT_ROOT}/ios/config/Options.ini" "${TARGET_GAMEDATA}/DefaultOptions.ini"
fi

# Strip Windows binaries from injected GameData
find "${TARGET_GAMEDATA}" -maxdepth 1 -type f \( -iname "*.exe" -o -iname "*.dll" -o -iname "*.dat" -o -iname "*.ico" -o -iname "*.lcf" -o -iname "*.txt" \) -delete

echo "==> [3/4] Packaging complete IPA into: ${OUTPUT_PATH}..."
rm -f "${OUTPUT_PATH}"
(cd "${TEMP_DIR}" && zip -r -q "${PROJECT_ROOT}/${OUTPUT_PATH}" Payload)

FINAL_SIZE="$(du -sh "${OUTPUT_PATH}" | cut -f1)"
echo "==> [4/4] Done!"
echo "SUCCESS: Created ${OUTPUT_PATH} (${FINAL_SIZE})"
echo ""
echo "Next Steps to Play on iPhone or iPad:"
echo "--------------------------------------"
echo "1. Connect your iPhone or iPad to your Mac/PC."
echo "2. Sideload '${OUTPUT_PATH}' using Sideloadly, AltStore, or TrollStore."
echo "3. On your iOS device, go to Settings > General > VPN & Device Management and Trust the profile."
echo "4. Launch Generals Zero Hour and enjoy native touch RTS!"
