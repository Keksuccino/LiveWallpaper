#!/usr/bin/env bash
# Pins a build to macOS 26, the app's minimum system version, and to the macOS 26 SDK. Exports
#   MACOSX_DEPLOYMENT_TARGET  for rustc and the C code cargo builds (Package.swift sets the Swift targets' own: .v26)
#   SDKROOT                   for SwiftPM, rustc and clang, in place of the active developer directory's default SDK
#   LW_SWIFTPM_FLAGS          extra flags for `swift build/test/run` (empty, or `--build-system native`, see below)
#   source scripts/macos-sdk.sh            (bash) pins the current shell; build.sh, build-scene-renderer.sh and CI do this
#   scripts/macos-sdk.sh swift test        runs one command with the pin (and LW_SWIFTPM_FLAGS for swift build/test/run)
# An SDKROOT that is already set has to be a macOS 26 SDK. Otherwise the active developer directory's default SDK is
# used when it is one (Xcode 26), else the newest MacOSX26.x SDK of the active developer directory, any Xcode in
# /Applications or the Command Line Tools (newer Command Line Tools also ship the previous SDK, MacOSX26.sdk).
# A macOS 26 SDK next to a newer toolchain is fine: a newer compiler builds against an older SDK, never the other way
# round, which is why the active toolchain's own SDK wins whenever it is a macOS 26 one.

LW_MACOS_MAJOR=26
export MACOSX_DEPLOYMENT_TARGET="$LW_MACOS_MAJOR.0"

lw_sdk_version() { plutil -extract Version raw "$1/SDKSettings.plist" 2>/dev/null || true; }
lw_is_target_sdk() {
  local version
  version="$(lw_sdk_version "$1")"
  [[ "$version" == "$LW_MACOS_MAJOR" || "$version" == "$LW_MACOS_MAJOR".* ]]
}
lw_real_path() { (cd "$1" 2>/dev/null && pwd -P) || true; }

LW_DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"

# `return` ends a sourced run; executed, it fails (silenced) and `exit` ends the script instead.
if [[ -n "${SDKROOT:-}" ]]; then
  if ! lw_is_target_sdk "$SDKROOT"; then
    echo "error: SDKROOT=$SDKROOT is not a macOS $LW_MACOS_MAJOR SDK (unset it to pick one automatically)." >&2
    return 1 2>/dev/null || exit 1
  fi
else
  LW_SDK=""
  if [[ -n "$LW_DEFAULT_SDK" ]] && lw_is_target_sdk "$LW_DEFAULT_SDK"; then
    LW_SDK="$LW_DEFAULT_SDK"
  else
    LW_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
    # Version-sorted, so the last line is the newest 26.x. Unmatched globs stay literal and fail the SDK check.
    LW_SDK="$(
      for sdk in "$LW_DEVELOPER_DIR"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX"$LW_MACOS_MAJOR"*.sdk \
                 /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX"$LW_MACOS_MAJOR"*.sdk \
                 /Library/Developer/CommandLineTools/SDKs/MacOSX"$LW_MACOS_MAJOR"*.sdk; do
        if lw_is_target_sdk "$sdk"; then printf '%s\t%s\n' "$(lw_sdk_version "$sdk")" "$sdk"; fi
      done | sort -t "$(printf '\t')" -k1,1V | tail -n 1 | cut -f 2
    )"
    unset LW_DEVELOPER_DIR
  fi
  if [[ -z "$LW_SDK" ]]; then
    echo "error: no macOS $LW_MACOS_MAJOR SDK found. Install Xcode $LW_MACOS_MAJOR (or newer Command Line Tools that" \
         "include MacOSX$LW_MACOS_MAJOR.sdk), or set SDKROOT to one." >&2
    return 1 2>/dev/null || exit 1
  fi
  export SDKROOT="$LW_SDK"
  unset LW_SDK
  echo "macOS $(lw_sdk_version "$SDKROOT") SDK: $SDKROOT (deployment target $MACOSX_DEPLOYMENT_TARGET)" >&2
fi

# SwiftPM's swiftbuild build system (the default in Swift 6.4) ignores SDKROOT and --sdk and always builds with the
# active developer directory's default SDK. Its native build system honours SDKROOT, so it is selected whenever the
# pinned SDK is not that default (a newer Xcode is the active one). With Xcode 26 active nothing changes.
LW_SWIFTPM_FLAGS=""
if [[ -z "$LW_DEFAULT_SDK" || "$(lw_real_path "$LW_DEFAULT_SDK")" != "$(lw_real_path "$SDKROOT")" ]]; then
  LW_SWIFTPM_FLAGS="--build-system native"
fi
export LW_SWIFTPM_FLAGS
unset LW_DEFAULT_SDK

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ $# -eq 0 ]]; then
    echo "usage: scripts/macos-sdk.sh command [argument ...]   (or: source scripts/macos-sdk.sh)" >&2
    exit 2
  fi
  if [[ "$1" == "swift" && "${2:-}" =~ ^(build|test|run)$ && -n "$LW_SWIFTPM_FLAGS" ]]; then
    # Word splitting of LW_SWIFTPM_FLAGS is intended: it holds whole flags.
    exec "$1" "$2" $LW_SWIFTPM_FLAGS "${@:3}"
  fi
  exec "$@"
fi
