#!/usr/bin/env bash
# Builds MeetingCopilot.app so macOS shows a proper microphone permission prompt for the app itself.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/MeetingCopilot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingCopilot "$APP/Contents/MacOS/"
# Copy SwiftPM resource bundles (WhisperKit tokenizer assets, etc.) if any.
find .build/release -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MeetingCopilot</string>
  <key>CFBundleDisplayName</key><string>Meeting Copilot</string>
  <key>CFBundleIdentifier</key><string>local.meetingcopilot</string>
  <key>CFBundleExecutable</key><string>MeetingCopilot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Transcribes meeting audio locally on this Mac.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
