#!/bin/sh
set -e
set -o pipefail

# Usage:
#   ./build_unsigned_and_sign.sh [output_dir] [codesign_identity]
#
# Where:
#   output_dir defaults to repo root.
#   codesign_identity is optional; when provided, the resulting app is signed.

SCRIPTS_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
XCODEPROJ="${ROOT_DIR}/Source/NimbleCommander/NimbleCommander.xcodeproj"

OUTPUT_DIR="${1:-${ROOT_DIR}}"
SIGN_IDENTITY="${2:-}"

SCHEME="NimbleCommander-Unsigned"
CONFIGURATION="Debug"

TARGET_APP_NAME="Nimble Commander.app"
TARGET_EXECUTABLE_NAME="Nimble Commander"

PBUDDY="/usr/libexec/PlistBuddy"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    # If we can't write into OUTPUT_DIR (e.g. /Applications), use sudo for privileged ops.
    if [ ! -w "${OUTPUT_DIR}" ]; then
        SUDO="sudo"
    fi
fi

echo "Building ${SCHEME}..."
xcodebuild -project "${XCODEPROJ}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" build
echo "Build succeeded."

# Resolve built .app path produced by the scheme.
APP_DIR="$(
    xcodebuild -project "${XCODEPROJ}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -showBuildSettings \
    | grep " BUILT_PRODUCTS_DIR =" \
    | sed -e 's/.*= *//'
)"
APP_NAME="$(
    xcodebuild -project "${XCODEPROJ}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -showBuildSettings \
    | grep " FULL_PRODUCT_NAME =" \
    | sed -e 's/.*= *//'
)"
SRC_APP="${APP_DIR}/${APP_NAME}"

DEST_APP="${OUTPUT_DIR}/${TARGET_APP_NAME}"
DEST_INFO_PLIST="${DEST_APP}/Contents/Info.plist"

if [ ! -d "${SRC_APP}" ]; then
    echo "Error: built app not found at: ${SRC_APP}"
    exit 1
fi

echo "Copying and patching to ${DEST_APP} ..."
${SUDO} rm -rf "${DEST_APP}"
${SUDO} mkdir -p "${OUTPUT_DIR}"
${SUDO} cp -R "${SRC_APP}" "${DEST_APP}"

# Rename the Mach-O executable inside the bundle to match CFBundleExecutable.
SRC_EXEC_NAME="$("${PBUDDY}" -c "Print :CFBundleExecutable" "${DEST_INFO_PLIST}")"
SRC_EXEC_PATH="${DEST_APP}/Contents/MacOS/${SRC_EXEC_NAME}"
TARGET_EXEC_PATH="${DEST_APP}/Contents/MacOS/${TARGET_EXECUTABLE_NAME}"

if [ ! -f "${SRC_EXEC_PATH}" ]; then
    echo "Error: executable not found at: ${SRC_EXEC_PATH}"
    exit 1
fi

${SUDO} mv "${SRC_EXEC_PATH}" "${TARGET_EXEC_PATH}"

# Patch Info.plist so the app reports the new executable (and Application Support folder name).
"${PBUDDY}" -c "Set :CFBundleExecutable \"${TARGET_EXECUTABLE_NAME}\"" "${DEST_INFO_PLIST}"
"${PBUDDY}" -c "Set :CFBundleName \"${TARGET_EXECUTABLE_NAME}\"" "${DEST_INFO_PLIST}" || true
"${PBUDDY}" -c "Set :CFBundleDisplayName \"${TARGET_EXECUTABLE_NAME}\"" "${DEST_INFO_PLIST}" || true

if [ -n "${SIGN_IDENTITY}" ]; then
    echo "Signing with: ${SIGN_IDENTITY}"
    ${SUDO} codesign --force --deep --sign "${SIGN_IDENTITY}" "${DEST_APP}"
fi

echo "Done: ${DEST_APP}"
echo "Application Support folder will be: ~/Library/Application Support/${TARGET_EXECUTABLE_NAME}"

