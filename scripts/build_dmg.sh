#!/bin/bash
#
# FontLoaderSub DMG Build Script
# Build, package, sign, and optionally notarize the macOS app as DMG.
#

set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
APP_NAME="FontLoaderSub"
APP_TARGET="FontLoaderSub"
DMG_NAME="FontLoaderSub"
BUILD_TYPE="${BUILD_TYPE:-Release}"
BUILD_DIR="${BUILD_DIR:-build}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-10.15}"
BUNDLE_ID="${BUNDLE_ID:-com.fontloadersub.app}"
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD="${APP_BUILD:-1}"
ENABLE_NOTARIZATION="${ENABLE_NOTARIZATION:-no}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_OUTPUT="$PROJECT_ROOT/$BUILD_DIR"
STAGING_DIR="$BUILD_OUTPUT/dmg-staging"
APP_BUNDLE_NAME="${APP_TARGET}.app"
APP_PATH="$BUILD_OUTPUT/$BUILD_TYPE/${APP_BUNDLE_NAME}"
DMG_OUTPUT="$PROJECT_ROOT/${DMG_NAME}.dmg"
SIGNING_IDENTITY=""

# --------------------------------------------------------------------------
# Functions
# --------------------------------------------------------------------------
print_info() {
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_warning() {
    echo "Warning: $1"
}

print_error() {
    echo "Error: $1" >&2
}

require_command() {
    local command_name="$1"
    local install_hint="$2"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        print_error "$command_name not found. $install_hint"
        exit 1
    fi
}

get_signing_candidates() {
    security find-identity -v -p codesigning 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *"Developer ID Application:"*|*"Apple Development:"*|*"Mac Developer:"*)
                printf '%s\n' "$line" | sed -E 's/.*"([^"]+)".*/\1/'
                ;;
        esac
    done
}

pick_unique_identity() {
    local preferred=()
    local fallback=()
    local identity

    while IFS= read -r identity; do
        [ -z "$identity" ] && continue
        if [[ "$identity" == *"Developer ID Application:"* ]]; then
            preferred+=("$identity")
        elif [[ "$identity" == *"Apple Development:"* ]] || [[ "$identity" == *"Mac Developer:"* ]]; then
            fallback+=("$identity")
        fi
    done < <(get_signing_candidates)

    if [ "${#preferred[@]}" -eq 1 ]; then
        printf '%s\n' "${preferred[0]}"
        return 0
    fi

    if [ "${#preferred[@]}" -gt 1 ]; then
        print_error "Multiple Developer ID Application certificates found. Please set CODE_SIGN_IDENTITY explicitly."
        printf '  %s\n' "${preferred[@]}" >&2
        return 1
    fi

    if [ "${#fallback[@]}" -eq 1 ]; then
        printf '%s\n' "${fallback[0]}"
        return 0
    fi

    if [ "${#fallback[@]}" -gt 1 ]; then
        print_error "Multiple development certificates found. Please set CODE_SIGN_IDENTITY explicitly."
        printf '  %s\n' "${fallback[@]}" >&2
        return 1
    fi

    return 1
}

resolve_signing_identity() {
    if [ -n "$CODE_SIGN_IDENTITY" ]; then
        SIGNING_IDENTITY="$CODE_SIGN_IDENTITY"
        echo "Using explicit signing identity: $SIGNING_IDENTITY"
        return 0
    fi

    SIGNING_IDENTITY=""
    echo "No CODE_SIGN_IDENTITY set. Building unsigned artifacts."
    return 0
}

check_prerequisites() {
    require_command cmake "Install CMake first."
    require_command xcodebuild "Install Xcode Command Line Tools first."
    require_command create-dmg "Install it with: brew install create-dmg"
    require_command codesign "Install Xcode Command Line Tools first."

    if [ "$ENABLE_NOTARIZATION" = "yes" ]; then
        require_command xcrun "Install Xcode Command Line Tools first."
        if [ -z "$NOTARY_PROFILE" ]; then
            print_error "ENABLE_NOTARIZATION=yes requires NOTARY_PROFILE to be set."
            exit 1
        fi
        if [ -z "$APPLE_TEAM_ID" ]; then
            print_error "ENABLE_NOTARIZATION=yes requires APPLE_TEAM_ID to be set."
            exit 1
        fi
    fi
}

step_1_cmake_configure() {
    print_info "Step 1: CMake Configuration"

    rm -rf "$BUILD_OUTPUT"

    cmake -S "$PROJECT_ROOT" -B "$BUILD_OUTPUT" \
        -G Xcode \
        -DMACOS_GUI=ON \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
        -DFONTLOADERSUB_BUNDLE_ID="$BUNDLE_ID" \
        -DFONTLOADERSUB_VERSION="$APP_VERSION" \
        -DFONTLOADERSUB_BUILD_NUMBER="$APP_BUILD"

    echo "CMake configuration completed."
}

step_2_build() {
    print_info "Step 2: Building $APP_TARGET"

    cmake --build "$BUILD_OUTPUT" \
        --config "$BUILD_TYPE" \
        --target "$APP_TARGET"

    echo "Build completed."
}

step_3_locate_app() {
    print_info "Step 3: Locating Built App"

    if [ ! -d "$APP_PATH" ]; then
        print_error "$APP_PATH not found"
        exit 1
    fi

    echo "Found app at: $APP_PATH"
}

step_4_codesign_app() {
    print_info "Step 4: Code Signing App"

    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "Skipping app signing."
        return 0
    fi

    codesign --force --deep \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        "$APP_PATH"

    codesign --verify --verbose=2 "$APP_PATH"
    echo "App signing completed."
}

step_5_create_dmg() {
    print_info "Step 5: Creating DMG"

    rm -f "$DMG_OUTPUT"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    cp -R "$APP_PATH" "$STAGING_DIR/"

    create-dmg \
        --volname "$APP_NAME" \
        --window-pos 400 200 \
        --window-size 600 400 \
        --icon-size 100 \
        --hide-extension "$APP_BUNDLE_NAME" \
        --icon "$APP_BUNDLE_NAME" 175 175 \
        --app-drop-link 425 175 \
        "$DMG_OUTPUT" \
        "$STAGING_DIR"

    echo "DMG created at: $DMG_OUTPUT"
}

step_6_sign_dmg() {
    print_info "Step 6: Signing DMG"

    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "Skipping DMG signing."
        return 0
    fi

    codesign --remove-signature "$DMG_OUTPUT" 2>/dev/null || true
    codesign --force \
        --sign "$SIGNING_IDENTITY" \
        "$DMG_OUTPUT"

    codesign --verify --verbose=2 "$DMG_OUTPUT"
    echo "DMG signing completed."
}

step_7_notarize() {
    print_info "Step 7: Notarization (Optional)"

    if [ "$ENABLE_NOTARIZATION" != "yes" ]; then
        echo "Skipping notarization."
        return 0
    fi

    if [ -z "$SIGNING_IDENTITY" ]; then
        print_error "Notarization requires a signing identity."
        exit 1
    fi

    xcrun notarytool submit "$DMG_OUTPUT" \
        --keychain-profile "$NOTARY_PROFILE" \
        --team-id "$APPLE_TEAM_ID" \
        --wait

    xcrun stapler staple "$DMG_OUTPUT"
    echo "Notarization completed."
}

step_8_verify() {
    print_info "Step 8: Final Verification"

    if [ ! -f "$DMG_OUTPUT" ]; then
        print_error "DMG file not found"
        exit 1
    fi

    echo "DMG file exists: $DMG_OUTPUT"
    ls -lh "$DMG_OUTPUT"

    if [ -n "$SIGNING_IDENTITY" ]; then
        echo ""
        echo "App signature verification:"
        codesign --verify --verbose=2 "$APP_PATH"

        echo ""
        echo "DMG signature verification:"
        codesign --verify --verbose=2 "$DMG_OUTPUT"
    fi

    echo ""
    echo "Build completed successfully!"
    echo "Output: $DMG_OUTPUT"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
    echo "FontLoaderSub DMG Build Script"
    echo "=============================="
    echo ""

    check_prerequisites
    resolve_signing_identity
    step_1_cmake_configure
    step_2_build
    step_3_locate_app
    step_4_codesign_app
    step_5_create_dmg
    step_6_sign_dmg
    step_7_notarize
    step_8_verify
}

main "$@"
