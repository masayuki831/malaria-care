#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "iOSのビルドにはmacOSとXcodeが必要です。GitHub ActionsのmacOSジョブも利用できます。" >&2
  exit 1
fi
mode="${1:-simulator}"
flutter config --enable-swift-package-manager
flutter pub get --enforce-lockfile
case "$mode" in
  simulator)
    flutter build ios --simulator --debug
    ;;
  unsigned)
    flutter build ios --release --no-codesign
    echo "未署名の.appです。このままiPhoneにはインストールできません。"
    ;;
  ipa)
    : "${IOS_BUNDLE_ID:?Appleに登録した固有のBundle IDを設定してください}"
    : "${IOS_TEAM_ID:?AppleのTeam IDを設定してください}"
    : "${IOS_EXPORT_OPTIONS:?Xcodeから書き出したExportOptions.plistの絶対パスを設定してください}"
    if [[ ! -f "$IOS_EXPORT_OPTIONS" ]]; then
      echo "ExportOptions.plistが見つかりません。docs/IOS.mdを参照してください。" >&2
      exit 1
    fi
    python3 tool/configure_ios.py --bundle-id "$IOS_BUNDLE_ID" --team-id "$IOS_TEAM_ID"
    flutter build ipa --release --export-options-plist "$IOS_EXPORT_OPTIONS"
    ;;
  *) echo "使い方: bash tool/build_ios.sh [simulator|unsigned|ipa]" >&2; exit 2 ;;
esac
