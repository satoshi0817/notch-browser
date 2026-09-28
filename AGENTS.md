# Codex rules for NotchBrowser

## リリース時の署名・公証（必須）

GitHub Releasesなどで配布する更新版は、リリースごとにDeveloper ID署名とApple公証を行う。公証は配布するコードに対する検証であり、以前のバージョンが公証済みでも更新版には引き継がれない。同一の公証済み成果物を変更せず再配布するだけなら再申請は不要。ローカル開発用ビルドには公証は不要。

公開前に次の手順を完了すること。

1. 最終版のアプリをApple Silicon / Intel両対応でビルドし、Developer ID Application証明書で署名する。Hardened Runtime、安全なタイムスタンプ、必要なentitlementsを含める。
2. その成果物をAppleへ公証申請し、受理を確認する。アップロード成功だけで公証完了と扱わない。
3. 公証チケットをアプリに添付する（`xcrun stapler staple`、またはXcodeの公証済みアプリのエクスポート）。添付後のアプリをZIPにする。公証後にアプリを編集・再ビルド・再署名した場合は、改めて公証する。
4. 配布用ZIPを展開し、以下がすべて成功することを確認する。
   - `codesign --verify --strict --all-architectures --verbose=2 <app>`
   - `xcrun stapler validate <app>`
   - `spctl --assess --type execute --verbose=2 <app>`（`accepted` / `Notarized Developer ID`）
5. 検証したZIPをGitHub Releaseへ公開する。リリース説明は公証済みのインストール手順に合わせ、通常のインストール方法としてquarantine属性の削除やGatekeeperの無効化を案内しない。
6. 公開ZIPを再ダウンロードし、ローカルで検証したZIPとSHA-256が一致すること、および署名・公証・Gatekeeperの検証が通ることを確認する。

認証が使えない、公証が処理中・失敗、検証に失敗した場合は、未公証版を代わりに公開しない。申請IDと現在の状況を報告し、同じ申請を確認して続行する。秘密キー・パスワードはソース管理やログに保存しない。

### 利用できる経路

- `SIGNING_IDENTITY`とnotarytoolのキーチェーンプロファイルを設定した場合：`./scripts/release.sh --notarize <profile>`。`--publish`を使う場合も必ず`--notarize`を併用する。引数なしの`release.sh`は公証しないので、その出力をそのまま公開しない。
- Xcodeに保存済みの開発者認証がある場合：対象の署名済みアプリから作成した`.xcarchive`を、`method=developer-id` / `destination=upload`のExportOptions.plistで`xcodebuild -exportArchive`に渡して申請できる。受理後に`xcodebuild -exportNotarizedApp -archivePath <archive> -exportPath <output>`で書き出し、その出力を検証・ZIP化する。v0.1.3ではこの経路で成功した。古いarchiveを新バージョンの代わりに再利用しない。

参考：
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
