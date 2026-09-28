# NotchBrowser

MacBook のノッチに住む、小さな WebKit ブラウザです。

ノッチにカーソルを乗せるとブラウザが広がり、離すと閉じます。メールやカレンダーなど、よく見るサイトをすぐに開けます。アプリ本体は約 2MB です。

## インストール

1. [Releases](https://github.com/satoshi0817/notch-browser/releases/latest) から `NotchBrowser-*.zip` をダウンロードして展開します。
2. `NotchBrowser.app` を「アプリケーション」フォルダに移動して開きます。
3. 「Apple は検証できませんでした」と表示されたら、**システム設定 › プライバシーとセキュリティ** を開き、「NotchBrowser」の **このまま開く** をクリックします。

   Apple の公証（notarization）を受けていないため、初回だけこの手順が必要です。ターミナルからは次のコマンドでも開けるようになります。

   ```sh
   xattr -dr com.apple.quarantine /Applications/NotchBrowser.app
   ```

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

カーソルを乗せて開いただけのときは、入力は元のアプリのままです。クリックするか `⌃⌥N` で開くと、ブラウザに文字を入力できます。

ブラウザ右上のピンを押すと、カーソルを外しても開いたままになります。

## 機能

- **固定タブ:** 名前・URL・アイコン（サイトのアイコン / SF Symbols / 絵文字 / 画像）を設定できます。アイコンのみの表示や、ドラッグでの並べ替えもできます。
- **プロファイル:** ログイン情報（Cookie）をプロファイルごとに分けられます。タブごとにプロファイルを選べます。
- **ディスプレイごとの設定:** 表示するディスプレイ、待機時の不透明度、開いたときのサイズを設定できます。
- **次の予定までの分数:** 予定の 30 分前（変更可）から、閉じたノッチの横に残り時間を表示します。Mac の「カレンダー」アプリの予定を使います。
- **画面共有に映らない:** Zoom や Google Meet などで画面を共有しても、ノッチのブラウザは相手に映りません（一部のアプリでは効かない場合があります）。
- **その他:** ノッチを開いたときに表示するタブの指定、アイコンのグレースケール表示、Raycast / Alfred / Spotlight を開いたときにその後ろへ下がる動作。

## 制限

- 表示できるのは Web サイトだけです。macOS ではほかのアプリのウィンドウを埋め込めないため、Slack などは Web 版を使ってください。
- Apple の公証を受けていないため、初回起動時に上記の手順が必要です。

## ソースからビルド

Xcode は不要で、Command Line Tools（Swift 5.9 以降）だけでビルドできます。

```sh
./scripts/build-app.sh               # build/NotchBrowser.app（このMacのアーキテクチャ）
./scripts/build-app.sh --universal   # Apple Silicon + Intel
open build/NotchBrowser.app
```

リリース用の zip は `./scripts/release.sh` で作れます。`--publish` を付けると、タグを付けて GitHub Release を公開します。

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
