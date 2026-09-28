# NotchBrowser

MacBook のノッチに住む、小さな WebKit ブラウザです。

ノッチにカーソルを乗せるとブラウザが広がり、離すと閉じます。メールやカレンダーなど、よく見るサイトをすぐに開けます。アプリ本体は約 2MB です。

## インストール

1. [Releases](https://github.com/satoshi0817/notch-browser/releases/latest) から `NotchBrowser-*.zip` をダウンロードして展開します。
2. `NotchBrowser.app` を「アプリケーション」フォルダに移動して開きます。
3. 初回に「インターネットからダウンロードしたアプリ」として確認された場合は、「開く」を選びます。

配布ZIPはDeveloper ID署名・Apple公証済みです。

**動作環境:** macOS 14 以降（Apple Silicon / Intel）。ノッチのない Mac や外部ディスプレイでは、画面上端の中央に表示されます。

## 使い方

| 操作 | |
|---|---|
| 開く | ノッチにカーソルを乗せる / クリック / `⌃⌥N` |
| 閉じる | カーソルを外す / `Esc` / ほかの場所をクリック / `⌃⌥N` |
| 新規タブ・閉じる | `⌘T` / `⌘W` |
| アドレスバー | `⌘L` |
| タブ切り替え | `⌘1`〜`⌘9` |
| 設定 | `⌘,` またはメニューバーのアイコン |
| 終了 | ブラウザ右上の電源ボタン / ノッチを右クリック › 終了 / メニューバーのアイコン / `⌘Q` |

カーソルを乗せて開いただけのときは、入力は元のアプリのままです。クリックするか `⌃⌥N` で開くと、ブラウザに文字を入力できます。操作した後も、カーソルを外すと設定した待ち時間で閉じます（ピン留め中とダイアログ表示中を除きます）。

ブラウザ右上のピンを押すと、カーソルを外しても開いたままになります。

## 機能

- **開閉の動き:** 設定の「動き」で、カーソルを乗せてから開く・外してから閉じる待ち時間（0〜3秒）、動き方（従来の動き／ゆっくり加速・減速／一定速度／なし）、開閉それぞれのアニメーション時間（0.05〜1.5秒）を変更できます。クリックやショートカットは待たずに開きます。
- **固定タブ:** 名前・URL・アイコン（サイトのアイコン / SF Symbols / 絵文字 / 画像）を設定できます。アイコンのみの表示や、ドラッグでの並べ替えもできます。
- **プロファイル:** ログイン情報（Cookie）をプロファイルごとに分けられます。タブごとにプロファイルを選べます。
- **ディスプレイごとの設定:** 表示するディスプレイ、待機時の不透明度、開いたときのサイズを設定できます。
- **次の予定までの分数:** 予定の 30 分前（変更可）から、閉じたノッチの横に残り時間を表示します。Mac の「カレンダー」アプリの予定を使います。
- **画面共有に映らない:** Zoom や Google Meet などで画面を共有しても、ノッチのブラウザは相手に映りません（一部のアプリでは効かない場合があります）。
- **その他:** ノッチを開いたときに表示するタブの指定、アイコンのグレースケール表示、Raycast / Alfred / Spotlight を開いたときにその後ろへ下がる動作。

## 制限

- 表示できるのは Web サイトだけです。macOS ではほかのアプリのウィンドウを埋め込めないため、Slack などは Web 版を使ってください。

## ソースからビルド

Xcode は不要で、Command Line Tools（Swift 5.9 以降）だけでビルドできます。

```sh
./scripts/build-app.sh               # build/NotchBrowser.app（このMacのアーキテクチャ）
./scripts/build-app.sh --universal   # Apple Silicon + Intel
open build/NotchBrowser.app
```

リリース用の zip は `./scripts/release.sh` で作れます。公開時は以下の署名・公証を行い、`--notarize <profile> --publish` を付けると、タグを付けて GitHub Release を公開します。

### Developer ID 署名と Apple 公証

キーチェーンに秘密鍵付きの Developer ID Application 証明書がある Mac では、次のように署名済み ZIP を作れます。

```sh
export SIGNING_IDENTITY='Developer ID Application: SATOSHI SUZUKI (4LPTZP2QZM)'
./scripts/release.sh
```

署名時は Hardened Runtime と安全なタイムスタンプを有効にします。`SIGNING_IDENTITY` 未指定の場合は開発用のアドホック署名です。署名だけでは公証済みにはなりません。

公証には、`xcrun notarytool store-credentials NotchBrowser` で認証情報をキーチェーンに保存してから、同じ環境変数を設定して実行します。秘密鍵やパスワードはリポジトリに保存しないでください。

```sh
./scripts/release.sh --notarize NotchBrowser
```

Apple の受理を確認した後、アプリに公証チケットを添付し、Gatekeeper の検証を通して ZIP を作り直します。公証結果は `build/notarization-result.json` に保存します。

## 構成

| ファイル | 役割 |
|---|---|
| `NotchController.swift` | ノッチのウィンドウ、開閉、ディスプレイごとの管理 |
| `BrowserViewController.swift` | タブ、アドレスバー、WebKit |
| `Settings.swift` / `SettingsView.swift` | 設定の保存と設定画面 |
| `Icons.swift` | タブアイコン、サイトのアイコンの取得 |
| `CalendarMonitor.swift` | 次の予定までの分数 |
| `LauncherWatcher.swift` | Raycast などが開いているかの確認 |
| `HotKey.swift` | `⌃⌥N` のグローバルショートカット |

## ライセンス

[MIT](LICENSE)
