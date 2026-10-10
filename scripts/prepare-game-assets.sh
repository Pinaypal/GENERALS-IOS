#!/usr/bin/env bash
# Prepares and exports clean retail assets for Command & Conquer Generals Zero Hour.
#
# Usage:
#   ./scripts/prepare-game-assets.sh "/path/to/Zero Hour"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

GAME_DIR="${1:-}"
EXPORT_DIR="${PROJECT_ROOT}/gameres-export"

echo "=========================================================="
echo " Command & Conquer Generals: Zero Hour Asset Preparation  "
echo "=========================================================="

if [[ -z "${GAME_DIR}" ]]; then
    SEARCH_CANDIDATES=(
        "${HOME}/Library/Application Support/Steam/steamapps/common/Command & Conquer Generals - Zero Hour"
        "${HOME}/Library/Application Support/Steam/steamapps/common/Command and Conquer Generals Zero Hour"
        "${HOME}/.steam/steam/steamapps/common/Command & Conquer Generals - Zero Hour"
        "${HOME}/.local/share/Steam/steamapps/common/Command & Conquer Generals - Zero Hour"
        "${HOME}/GeneralsX/GeneralsZH"
    )
    for cand in "${SEARCH_CANDIDATES[@]}"; do
        if [[ -d "${cand}" ]] && find "${cand}" -maxdepth 1 -iname "*INIZH.big" | grep -q .; then
            GAME_DIR="${cand}"
            break
        fi
    done
fi

if [[ -z "${GAME_DIR}" || ! -d "${GAME_DIR}" ]]; then
    read -r -p "Enter path to Zero Hour install folder: " GAME_DIR
fi

if [[ -z "${GAME_DIR}" || ! -d "${GAME_DIR}" ]]; then
    echo "ERROR: Invalid game directory: '${GAME_DIR}'"
    exit 1
fi

rm -rf "${EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}"

echo "==> Copying Zero Hour .big archives..."
find "${GAME_DIR}" -maxdepth 1 -iname "*.big" -exec cp {} "${EXPORT_DIR}/" \;

# Copy folders
for sub in Data Maps Window Movies; do
    SUB_SRC="$(find "${GAME_DIR}" -maxdepth 1 -iname "${sub}" | head -1)"
    if [[ -n "${SUB_SRC}" && -d "${SUB_SRC}" ]]; then
        echo "==> Copying ${sub}..."
        cp -R "${SUB_SRC}" "${EXPORT_DIR}/"
    fi
done

# Copy ZH_Generals
ZH_GEN_DIR="$(find "${GAME_DIR}" -maxdepth 1 -iname "ZH_Generals" | head -1)"
if [[ -n "${ZH_GEN_DIR}" && -d "${ZH_GEN_DIR}" ]]; then
    echo "==> Copying base game data (ZH_Generals)..."
    cp -R "${ZH_GEN_DIR}" "${EXPORT_DIR}/"
else
    PARENT="$(dirname "${GAME_DIR}")"
    for cand in "${PARENT}/Command & Conquer Generals" "${PARENT}/Command and Conquer Generals" "${PARENT}/Generals"; do
        if [[ -d "${cand}" ]] && find "${cand}" -maxdepth 1 -iname "INI.big" | grep -q .; then
            echo "==> Found base game at: ${cand}. Staging ZH_Generals..."
            DEST_ZH="${EXPORT_DIR}/ZH_Generals"
            mkdir -p "${DEST_ZH}"
            find "${cand}" -maxdepth 1 -iname "*.big" -exec cp {} "${DEST_ZH}/" \;
            for d in Data Maps Window; do
                if [[ -d "${cand}/${d}" ]]; then cp -R "${cand}/${d}" "${DEST_ZH}/"; fi
            done
            break
        fi
    done
fi

# Fonts
mkdir -p "${EXPORT_DIR}/fonts"
"${SCRIPT_DIR}/build/ios/stage-fonts.sh" 2>/dev/null || true
if [[ -d "${PROJECT_ROOT}/build/ios-staging/fonts" ]]; then
    cp "${PROJECT_ROOT}/build/ios-staging/fonts"/*.ttf "${EXPORT_DIR}/fonts/" 2>/dev/null || true
fi

# Config
if [[ -f "${PROJECT_ROOT}/ios/config/dxvk.conf" ]]; then
    cp "${PROJECT_ROOT}/ios/config/dxvk.conf" "${EXPORT_DIR}/dxvk.conf"
fi
if [[ -f "${PROJECT_ROOT}/ios/config/Options.ini" ]]; then
    cp "${PROJECT_ROOT}/ios/config/Options.ini" "${EXPORT_DIR}/DefaultOptions.ini"
fi

# Strip Windows executables
find "${EXPORT_DIR}" -maxdepth 1 -type f \( -iname "*.exe" -o -iname "*.dll" -o -iname "*.dat" -o -iname "*.ico" -o -iname "*.lcf" -o -iname "*.txt" \) -delete

COUNT="$(find "${EXPORT_DIR}" | wc -l | tr -d ' ')"
echo "==> SUCCESS: Exported ${COUNT} files to ${EXPORT_DIR}"
