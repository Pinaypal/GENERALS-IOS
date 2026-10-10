#!/usr/bin/env bash
# Build GeneralsXZH (Zero Hour) for iOS (Apple Silicon arm64 device)
#
# Prerequisites (install once on macOS):
#   brew install cmake ninja meson pkg-config autoconf autoconf-archive automake libtool glslang xcodegen
#   Install Vulkan SDK or export VULKAN_SDK pointing to LunarG SDK macOS directory
#   vcpkg set up with arm64-ios triplet
#
# Usage:
#   ./scripts/build/ios/build-ios-zh.sh                      # configure + build engine
#   ./scripts/build/ios/build-ios-zh.sh --build-only         # skip configure if already configured
#   ./scripts/build/ios/build-ios-zh.sh --package            # build engine + package shell app
#   ./scripts/build/ios/build-ios-zh.sh --ipa                # build engine + package unsigned IPA
#   ./scripts/build/ios/build-ios-zh.sh --ipa --dev          # build engine + shell IPA without bundling retail data
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${PROJECT_ROOT}"

PRESET="ios-vulkan"
BUILD_DIR="${PROJECT_ROOT}/build/${PRESET}"
LOG_FILE="${PROJECT_ROOT}/logs/build_zh_${PRESET}.log"
SKIP_CONFIGURE=0
DO_PACKAGE=0
DO_IPA=0
DEV_MODE=0
UNSIGNED_MODE=1

for arg in "$@"; do
    case "$arg" in
        --build-only) SKIP_CONFIGURE=1 ;;
        --package)    DO_PACKAGE=1 ;;
        --ipa)        DO_IPA=1; DO_PACKAGE=1 ;;
        --dev)        DEV_MODE=1 ;;
        --signed)     UNSIGNED_MODE=0 ;;
    esac
done

mkdir -p logs

echo "==> Building GeneralsXZH for iOS (preset: ${PRESET})..."

# ── Prerequisite checks ──────────────────────────────────────────────────────

check_tool() {
    local tool="$1" hint="$2"
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: '$tool' not found. ${hint}"
        exit 1
    fi
}

check_tool cmake "brew install cmake"
check_tool ninja "brew install ninja"
check_tool meson "brew install meson"
check_tool python3 "brew install python3"
check_tool xcodegen "brew install xcodegen"

# Auto-detect VCPKG_ROOT
resolve_vcpkg_root() {
    local candidate=""
    local -a candidates=()
    local brew_vcpkg_root=""

    if [[ -n "${VCPKG_ROOT:-}" ]]; then
        if [[ -f "${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" ]]; then
            echo "Using VCPKG_ROOT from environment: ${VCPKG_ROOT}"
            return 0
        fi
        echo "WARNING: VCPKG_ROOT is set but invalid: ${VCPKG_ROOT}"
    fi

    if command -v brew &>/dev/null; then
        brew_vcpkg_root="$(brew --prefix vcpkg 2>/dev/null || true)"
    fi

    candidates+=("${PROJECT_ROOT}/vcpkg")
    candidates+=("${HOME}/vcpkg")
    candidates+=("/opt/vcpkg")
    candidates+=("/opt/homebrew/opt/vcpkg")
    candidates+=("/usr/local/opt/vcpkg")
    if [[ -n "${brew_vcpkg_root}" ]]; then
        candidates+=("${brew_vcpkg_root}")
    fi

    for candidate in "${candidates[@]}"; do
        if [[ -f "${candidate}/scripts/buildsystems/vcpkg.cmake" ]]; then
            export VCPKG_ROOT="${candidate}"
            echo "Using detected VCPKG_ROOT: ${VCPKG_ROOT}"
            return 0
        fi
    done

    echo "ERROR: VCPKG_ROOT is not configured and no local vcpkg installation was detected."
    echo "Install vcpkg: git clone https://github.com/microsoft/vcpkg.git ~/vcpkg && ~/vcpkg/bootstrap-vcpkg.sh"
    exit 1
}

resolve_vcpkg_root

# Vulkan SDK check
RESOLVED_VULKAN_SDK=""
for sdk_candidate in "${VULKAN_SDK:-}" "${VULKAN_SDK_ROOT:-}" "${HOME}/VulkanSDK"/*/macOS "${HOME}/VulkanSDK"/*; do
    [[ -n "${sdk_candidate}" ]] || continue
    if [[ -d "${sdk_candidate}/include" && -f "${sdk_candidate}/lib/MoltenVK.xcframework/ios-arm64/libMoltenVK.a" ]]; then
        RESOLVED_VULKAN_SDK="${sdk_candidate}"
        break
    elif [[ -d "${sdk_candidate}/macOS/include" && -f "${sdk_candidate}/macOS/lib/MoltenVK.xcframework/ios-arm64/libMoltenVK.a" ]]; then
        RESOLVED_VULKAN_SDK="${sdk_candidate}/macOS"
        break
    fi
done

if [[ -z "${RESOLVED_VULKAN_SDK}" ]]; then
    # Check if user set VULKAN_SDK directly
    if [[ -n "${VULKAN_SDK:-}" && -d "${VULKAN_SDK}" ]]; then
        RESOLVED_VULKAN_SDK="${VULKAN_SDK}"
    else
        echo "WARNING: LunarG Vulkan SDK with iOS MoltenVK.xcframework not auto-detected."
        echo "Set VULKAN_SDK pointing to your Vulkan SDK directory (e.g. ~/VulkanSDK/1.4.341.1/macOS)"
    fi
else
    export VULKAN_SDK="${RESOLVED_VULKAN_SDK}"
    echo "Using detected VULKAN_SDK: ${VULKAN_SDK}"
fi

# ── Initialize submodules ────────────────────────────────────────────────────
if [[ ! -d "references/fbraz3-dxvk/.git" && ! -f "references/fbraz3-dxvk/.git" ]]; then
    echo "==> Initializing references/fbraz3-dxvk submodule (required for iOS DXVK build)..."
    git submodule update --init references/fbraz3-dxvk
fi

# ── Fetch dependencies ───────────────────────────────────────────────────────
chmod +x scripts/build/ios/*.sh 2>/dev/null || true
echo "==> Staging dynamic MoltenVK..."
"${SCRIPT_DIR}/fetch-moltenvk.sh"

echo "==> Staging Liberation fonts..."
"${SCRIPT_DIR}/stage-fonts.sh"

# ── CMake Configure ──────────────────────────────────────────────────────────
if [[ "${SKIP_CONFIGURE}" -eq 0 ]]; then
    echo "==> Configuring CMake preset '${PRESET}'..."
    cmake --preset "${PRESET}" 2>&1 | tee "${LOG_FILE}"
    echo "Configure completed successfully."
fi

# ── CMake Build ──────────────────────────────────────────────────────────────
echo "==> Compiling z_generals (Generals Zero Hour iOS)..."
cmake --build "${BUILD_DIR}" --target z_generals 2>&1 | tee -a "${LOG_FILE}"

echo "==> Compilation successful: ${BUILD_DIR}/GeneralsMD/GeneralsXZH"

# ── Optional Packaging ───────────────────────────────────────────────────────
if [[ "${DO_PACKAGE}" -eq 1 ]]; then
    PACKAGE_ARGS=()
    if [[ "${DEV_MODE}" -eq 1 ]]; then
        PACKAGE_ARGS+=(--dev)
    fi
    if [[ "${UNSIGNED_MODE}" -eq 1 ]]; then
        PACKAGE_ARGS+=(--unsigned)
    fi
    if [[ "${DO_IPA}" -eq 1 ]]; then
        PACKAGE_ARGS+=(--ipa)
    fi

    echo "==> Packaging iOS application (${PACKAGE_ARGS[*]:-default})..."
    "${SCRIPT_DIR}/package-ios-zh.sh" "${PACKAGE_ARGS[@]}"
fi

echo "==> All done!"
