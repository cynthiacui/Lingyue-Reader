#!/usr/bin/env bash
# Build a deterministic Debug fixture and capture the 我 tab at App Store Connect's
# iPhone 6.5-inch and iPad 13-inch accepted pixel sizes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${TMPDIR:-/tmp}/lingyue-release-screenshots-derived"
CAPTURE_DIR="${TMPDIR:-/tmp}/lingyue-release-screenshots"
BUNDLE_ID="com.lingyue.reader"
SCHEME="LingyueAppStore"

IPHONE_NAME="Lingyue Release iPhone 6.5"
IPHONE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max"
IPHONE_OUTPUT="$REPO_ROOT/docs/screenshots/08-me.png"

IPAD_NAME="Lingyue Release iPad 13"
IPAD_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"
IPAD_OUTPUT="$REPO_ROOT/docs/screenshots/ipad-me.png"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command '$1' was not found" >&2
    exit 69
  }
}

require_command jq
require_command ffmpeg
require_command sips
require_command xcodebuild
require_command xcrun

runtime_identifier="$(
  xcrun simctl list runtimes --json |
    jq -r '
      [.runtimes[] | select(.isAvailable and .platform == "iOS")] as $ios
      | (($ios | map(select(.version | startswith("18."))) | last)
          // ($ios | sort_by(.version) | last)
          // empty)
      | .identifier
    '
)"

if [[ -z "$runtime_identifier" ]]; then
  echo "error: no available iOS Simulator runtime was found" >&2
  exit 70
fi

simulator_id() {
  local name="$1"
  local device_type="$2"
  local existing
  existing="$(
    xcrun simctl list devices --json |
      jq -r --arg name "$name" '
        [.devices[][] | select(.name == $name and .isAvailable)] | first.udid // empty
      '
  )"
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"
  else
    xcrun simctl create "$name" "$device_type" "$runtime_identifier"
  fi
}

mkdir -p "$CAPTURE_DIR" "$REPO_ROOT/docs/screenshots"

echo "Building $SCHEME screenshot fixture..."
xcodebuild \
  -project "$REPO_ROOT/lingyue.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

app_path="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/LingyueAppStore.app"
if [[ ! -d "$app_path" ]]; then
  echo "error: built app was not found at $app_path" >&2
  exit 66
fi

capture_device() {
  local device_name="$1"
  local device_type="$2"
  local expected_width="$3"
  local expected_height="$4"
  local output="$5"
  local udid
  local raw_capture="$CAPTURE_DIR/${device_name// /-}-raw.png"
  local flattened_capture="$CAPTURE_DIR/${device_name// /-}.png"

  udid="$(simulator_id "$device_name" "$device_type")"
  echo "Capturing $device_name ($udid)..."

  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --batteryState charged \
    --batteryLevel 100 \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4

  xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$udid" "$app_path"
  xcrun simctl launch "$udid" "$BUNDLE_ID" \
    --screenshot-me \
    --screenshot-fixture >/dev/null
  sleep 3

  xcrun simctl io "$udid" screenshot "$raw_capture" >/dev/null
  ffmpeg \
    -y \
    -loglevel error \
    -i "$raw_capture" \
    -map_metadata -1 \
    -pix_fmt rgb24 \
    "$flattened_capture"

  local width height alpha
  width="$(sips -g pixelWidth "$flattened_capture" | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$flattened_capture" | awk '/pixelHeight/ { print $2 }')"
  alpha="$(sips -g hasAlpha "$flattened_capture" | awk '/hasAlpha/ { print $2 }')"
  if [[ "$width" != "$expected_width" || "$height" != "$expected_height" ]]; then
    echo "error: $device_name produced ${width}x${height}, expected ${expected_width}x${expected_height}" >&2
    exit 65
  fi
  if [[ "$alpha" != "no" ]]; then
    echo "error: $device_name screenshot still contains an alpha channel" >&2
    exit 65
  fi

  cp "$flattened_capture" "$output"
  xcrun simctl shutdown "$udid"
  echo "Wrote $output (${width}x${height}, RGB)"
}

capture_device "$IPHONE_NAME" "$IPHONE_TYPE" 1242 2688 "$IPHONE_OUTPUT"
capture_device "$IPAD_NAME" "$IPAD_TYPE" 2064 2752 "$IPAD_OUTPUT"
