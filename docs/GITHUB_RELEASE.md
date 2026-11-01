# GitHub Desktopで0.8版を配布する

GitHubへのアップロード自体はまだ行っていません。次の2つを別々に使います。

- `malaria-care-github-source-v0.8.zip`：Codeに置くソース一式
- `malaria-care-github-release-v0.8.zip`：Releasesに添付するAPK・確認用ハッシュ・説明文

## 1. GitHub Desktopでソースを公開する

### まだリポジトリを作っていない場合

1. GitHub Desktopを開き、自分のGitHubアカウントでログインします。
2. File → New repositoryを選び、次の内容でCreate repositoryを押します。
   - Name：`malaria-care`
   - Local path：保存先を選択。ここで選んだ場所の中に`malaria-care`フォルダーが作られます。
   - Initialize this repository with a README：チェックしない
   - Git ignore：None
   - License：None（同梱の独自LICENSE.mdを使うため、テンプレートで上書きしません）
3. ソース用ZIPを別の場所へ展開します。
4. 展開された`malaria-care-github`の**中身すべて**を、GitHub Desktopで作った`malaria-care`フォルダーへコピーします。`malaria-care-github`という外側のフォルダーごと入れないでください。コピー先の直下に`lib`・`ios`・`.github`・`pubspec.yaml`・`README.md`が並べば正しい状態です。
5. GitHub Desktopへ戻り、Changesにソースが表示されることを確認します。APKはここには入れません。
6. Summaryへ`Add Malaria Care 0.8`と入力し、Commit to mainを押します。ブランチ名がmain以外なら、その名前のCommitボタンを使います。
7. Publish repositoryを押します。誰でも取得できる公開にする場合は**Keep this code privateのチェックを外し**、Publish Repositoryで公開します。Privateのまま使う場合は、閲覧できる利用者を個別に招待します。
8. Repository → View on GitHubで、公開されたページを開きます。

### GitHub側に同名のリポジトリを作成済みの場合

新しくNew repositoryで作らず、File → Clone repositoryからそのリポジトリを選びます。Clone先へソースZIPの中身をコピーし、Commit → Push originを行ってください。

CodeにはAPKや署名鍵を置きません。用意したソースZIPには、端末固有の設定・生成済みビルド・個人の保存データは含めていません。

## 2. Android版をReleasesに添付する

1. 配布用ZIPを展開します。
2. リポジトリのReleases → Draft a new releaseを開きます。
3. Tagを`v0.8`、Titleを`Malaria Care 0.8`とします。
4. `RELEASE_NOTES.md`の内容を説明欄へ貼り付けます。
5. `malaria-care-v0.8.apk`・`SHA256SUMS.txt`・`LICENSE.md`を添付します。必要なら`利用者向け案内.md`も添付します。
6. 本番前の検証版なのでSet as a pre-releaseをONにして公開します。
7. 公開したReleasesページのURLを試す方へ案内します。

## 3. 利用者へ伝える内容

Android利用者はReleasesのAPKを開いてインストールします。更新時はアンインストールしません。取得前に利用条件を確認するよう案内します。通知は新規利用時に両方OFFで、設定からONにできます。APKを転載・再配布せず、配布元のリンクを共有してもらいます。

iPhone利用者はAPKを使えません。現時点ではiPhoneへの配布準備中と案内してください。GitHubにIPAという名前のファイルを置くだけで通常のiPhoneへインストールできるわけではありません。

## 4. iPhoneのビルド確認だけを実行する

ソースをアップロードした後、Actions → Build iOS simulator app → Run workflowを選びます。成功すると確認用アプリがArtifactsに保存されます。iPhoneへのインストール用ではありません。次にCheck iOS device build (unsigned)を実行すると実機向けコードのコンパイルも確認できます。

Macのジョブは自動実行せず、ボタンを押した場合だけ動作します。利用枠・料金は自分のGitHubアカウントのActions設定で確認してください。

参照：[GitHubのリリース作成](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)、[ファイルの追加](https://docs.github.com/en/repositories/working-with-files/managing-files/adding-a-file-to-a-repository)。

GitHub Desktopの参照：[最初のリポジトリを作る](https://docs.github.com/en/desktop/overview/creating-your-first-repository-using-github-desktop)、[リポジトリの公開](https://docs.github.com/en/desktop/adding-and-cloning-repositories/adding-an-existing-project-to-github-using-github-desktop)。
