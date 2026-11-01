# iPhone版の現在地と配布まで

## 現時点で用意したもの

- Androidと共通の服用・在庫・PDF・バックアップ機能
- iOS 15.0以上向けのXcodeプロジェクトとSwift Package Manager構成
- 通知権限の確認、前日確認の背景処理用登録
- iOSの制限を超えないよう、日時順で直近64件だけをOSへ予約する処理
- iOS通知設定と予約の自動テスト
- GitHubのMacで動かす手動ビルドワークフロー
- 固有のBundle IDとApple Teamを設定する補助ツール

Windowsでのテストと設定ファイルの確認を行っています。**Xcodeでのビルド、シミュレーター起動、iPhone実機確認、Appleへの提出、署名済みIPAの作成はまだ行っていません。** 準備済みのソースを、配布可能なiPhoneアプリが完成したという意味では扱わないでください。

## TestFlightとは

Appleのテスト配布サービスです。開発者が署名済みアプリをApp Store Connectへ登録し、利用者はAppleのTestFlightアプリからインストールします。他の人へのテスト配布にはApple Developer Programの登録が必要です。

GitHubはソースとAndroidのAPKを置く場所として使えますが、iPhoneの署名やTestFlightを置き換えるものではありません。現在MacやAppleの登録がなくても、GitHubのmacOSジョブで署名前のビルド確認はできます。

## まずGitHubでビルド確認する

1. ソースをGitHubへアップロードします。
2. Actions → Build iOS simulator appを手動実行します。
3. 成功したらCheck iOS device build (unsigned)も実行します。
4. 失敗した場合はログの内容を確認します。これらのワークフローはこの作業環境からは実行していません。

どちらの出力も、通常のiPhoneにインストールするための署名は付いていません。

## Macが使える場合

Flutter 3.47.9とXcodeを用意し、次を実行します。

```sh
flutter pub get --enforce-lockfile
bash tool/build_ios.sh simulator
```

Xcodeで開く前の設定生成は次のコマンドでも実行できます。

```sh
flutter build ios --config-only --no-codesign
open ios/Runner.xcworkspace
```

自分のiPhoneで試す場合は、XcodeへApple Accountを登録し、Signing & CapabilitiesでTeamを選択します。無料のPersonal Teamでの端末テストは配布用の仕組みとは異なり、有効期限などの制約があります。

## 他の人へTestFlightで配布する場合

1. Apple Developer Programへ登録します。
2. App Store ConnectでMalaria Careのアプリ情報を作成します。
3. Appleに登録した固有のBundle IDとTeam IDを用意します。現在の`com.example.malariacare`は確認用の仮IDであり、登録済みIDではありません。
4. Macで設定します。以下の値は実際の登録値へ置き換えます。

```sh
python3 tool/configure_ios.py --bundle-id com.yourcompany.malariacare --team-id ABCDE12345
flutter build ios --config-only
open ios/Runner.xcworkspace
```

5. Xcodeでアカウントと署名を設定し、Product → Archive → Distribute AppからApp Store Connectへ送ります。
6. TestFlightでテスターを登録し、必要な確認・審査を終えて案内します。

Macを自分で所有せずクラウドで署名する場合も、Apple側の登録・証明書・プロビジョニング設定が必要です。アカウントや証明書を取得した後に署名用CIを設定してください。この資料には秘密鍵・署名証明書やアカウント情報を含めていません。

Xcodeで書き出したExportOptions.plistと署名設定が揃ったMacでは、`IOS_BUNDLE_ID`・`IOS_TEAM_ID`・`IOS_EXPORT_OPTIONS`を環境変数に設定し、`bash tool/build_ios.sh ipa`を実行できます。ビルド番号はTestFlightへ新しいビルドを送るたびに増やしてください。

## 実機で確認すること

- 初期状態で通知2種類がOFF、ONにした際のOS権限確認、拒否後の表示
- 当日リマインダーと前日確認、通知音と端末の消音設定
- 通知アクションを押したときの保存と、アプリを開き直した後の記録
- 予定のない日への遅延、予定のある日への移動拒否
- PDFの保存・共有・添付メール、保存したバックアップからの復元
- アプリ再起動後・日付やタイムゾーン変更後の通知更新

iPhoneの通知ボタンの見た目とバイブはOSが管理します。Androidの角丸ボタンと全く同じ表示を強制する構成にはしていません。長期間起動しない場合、有限の予約が尽きると通知は止まるため、アプリを定期的に開いて更新します。

## 参照

- [Flutter：iOSのビルドと配布](https://docs.flutter.dev/deployment/ios)
- [Flutter：Swift Package Manager](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)
- [Apple：DeveloperアカウントとPersonal Team](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [通知ライブラリ：iOSの予約上限](https://github.com/MaikuB/flutter_local_notifications/tree/master/flutter_local_notifications#ios-pending-notifications-limit)
