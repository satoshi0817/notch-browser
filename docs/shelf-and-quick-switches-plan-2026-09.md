# ファイル棚とクイックスイッチの調査・実装案

調査日: 2026-09-29。対象: NotchBrowser v0.2.2、macOS 14以降。
今回は調査と設計のみ。アプリのコード、OS設定、権限、リリースは変更していない。
製品の仕様は公式情報、実装候補はApple資料・ローカルSDK・既存コードから整理した。競合アプリを実機操作した評価ではない。以下の採用判断は提案であり、機能の人気を数値で確認したものではない。

## 推奨する方向

先に「ファイルの一時置き場」と「少数のクイック操作」を追加する。常時コピー履歴の収集やOne Switchの全機能再現は後段に分ける。

- ノッチの外形と上部1段の配置は維持する。入口は既存の操作メニューに「ファイル棚」「スイッチ」を追加。
- 通常はブラウザを表示。棚・スイッチを開いてもWKWebViewを破棄せず、戻ったときに入力・スクロール・ログインを保つ。
- 有効な外部ファイルのドラッグ開始で、小型の棚を一時表示する方式を標準とする。ノッチへの接近時だけ表示する方式も選べる。[追加の競合調査と表示方式の更新](drag-shelf-comparison-2026-09.md)を参照。ドラッグ開始の検出は別途試作が必要。
- スイッチは大きめのカード。よく使うものだけ表示し、設定は「標準」「作業」「カスタム」などの構成選択にする。カスタムは保存で閉じる。
- 操作アイコンはSF Symbolsに統一。ファイルの画像プレビューは内容として表示し、アプリの操作アイコンとは分ける。絵文字は使わない。

## 競合から確認できたこと

### Yoink

[公式製品ページ](https://eternalstorms.at/yoink/mac/)では、ファイルや他アプリのコンテンツを一時保管してドラッグし直す棚、ドラッグ時の出現、複数画面・Spaces間での利用、Quick Look、クリップボード履歴を案内している。Finderに近い移動／コピー操作も特徴。

[公式プライバシーポリシー](https://eternalstorms.at/privacypolicy/)では、コピー履歴は初期状態で無効、ローカル保存、除外アプリや機密データ種別への対応が明記されている。ファイル棚と常時コピー履歴は別の設定・機能として設計するのが適切。

[3.7公式リリースノート](https://updates.eternalstorms.at/notes/YNKMC/3.7)には、ドラッグ、画面構成変更、再起動後のファイル参照、ブラウザ互換性の修正がある。この種の機能はカードUIより、ファイルの寿命と外部アプリとの互換性に検証工数がかかる。

### One Switch

[公式製品ページ](https://fireball.studio/oneswitch)は、デスクトップアイコン非表示、ダークモード、スリープ抑止、スクリーンセーバー、AirPods接続を紹介している。[公式更新情報](https://fireball.studio/api/release_manager/releasenotes/429/en/studio.fireball.OneSwitchOfficial.xml)にはmacOS 26や蓋を閉じた状態の機種別対応もある。

NotchBrowserでは「何でも同じトグルで操作する」より、状態を確認できるスイッチと、一度実行するアクションを明確に分ける。競合と同等のハードウェア対応を前提にしない。

## ファイル棚: 最初に作る範囲

| 操作 | 初期案 |
|---|---|
| 追加 | Finderからファイル・フォルダをドロップ。明示的な「クリップボードから追加」も用意 |
| 一時保管 | 元ファイルの参照を保持。大きいフォルダを勝手に複製しない |
| 取り出す | 複数選択してFinder・対応アプリへドラッグ。初期版はコピー操作を提示し、元ファイルを移動・削除しない |
| 見る | 名前・種類・サイズ、画像/PDF等のサムネイル、SpaceでQuick Look、Finderで表示 |
| 整理 | 複数追加をグループ化、ピン留め、棚から外す、まとめてクリア |
| 再起動 | ファイル参照と並びを保存。見つからない項目は明示し、再選択／棚から外すを選べる |
| ブラウザ連携 | ダウンロード完了時に棚へ追加するオプション。既存の保存先は変えない |

「棚から外す」は参照を消す操作。元のファイルの削除ではない。初期版ではドラッグ成功後も項目を残し、消えたかどうかを気にせず繰り返し使える設計を推奨する。

### 実装構成

- `ShelfStore`: 項目ID、表示名、種類、URL bookmark、追加日時、グループID、ピン留め、所有区分を保存。小規模な初期版はJSONをApplication Supportにアトミック保存する。ファイル本体をUserDefaultsへ入れない。
- 所有区分は `externalReference` と `managedContent` に分ける。外部ファイルは参照のみ。Web画像やMail添付のようにドロップ時に生成されるデータは、アプリ管理下のUUID別ディレクトリへ非同期で受け取る。
- `ShelfDropView`: AppKitの `NSDraggingDestination` で受け入れ、`NSDraggingSource` / `NSDraggingItem` で取り出す。[Apple Drag and Drop](https://developer.apple.com/documentation/AppKit/drag-and-drop)
- 外部ファイルURLと `NSFilePromiseReceiver` を分ける。ファイルpromiseの受信完了までは「取り込み中」と表示し、失敗を項目単位で処理する。Mail添付・各ブラウザの画像は互換性試験後に対応範囲を確定する。[Apple File Promise](https://developer.apple.com/documentation/appkit/nsfilepromisereceiver)
- `ShelfPreviewService`: `QLThumbnailGenerator` で必要な項目だけ非同期生成。一般ファイルの代替表示はSF Symbols。Quick Lookにも既存の画面共有非表示設定を適用できるか確認する。[Apple Thumbnail Generator](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator)
- パスだけでなくbookmarkを使い、解決時にstaleなら再生成する。元ファイル削除・外付けディスク取り外しでは復旧不能なケースを扱う。bookmarkはアクセス権を無条件に保証するものではない。[Apple Bookmark API](https://developer.apple.com/documentation/foundation/nsurl/bookmarkdata%28withcontentsof%3A%29)
- 現在の配布アプリはApp Sandboxのentitlementを持たない。将来Sandbox化するならsecurity-scoped bookmarkとアクセス開始／終了の対応を別途実装する。初期版からフルディスクアクセスを必須にしない。
- 棚はMac全体の作業用としてブラウザのログインプロファイルとは別管理。常時クリップボード監視は初期版では行わない。
- 管理コピーには容量上限・削除条件を設ける。受信中／ドラッグ提供中／プレビュー中のファイルは削除せず、ピン留めは自動掃除から除外する。具体的な上限は試作時に決める。

### ノッチ固有の注意点

現在のノッチは `mouseEntered` / `mouseExited` で開閉しており、ドラッグを受けるルートがない。ドラッグ中のホバーイベントだけに依存せず、閉じたノッチの受信領域で `draggingEntered` を扱う必要がある。

- カメラの左右にある操作可能な領域で受信できるか、実際のノッチ付きMacで先に試す。
- ドラッグ開始から終了まで `dragSessionActive` を持ち、既存の自動クローズを一時停止する。離脱／キャンセル時には必ず解除。
- NSViewのドラッグターゲットを開閉アニメーション途中で消さない。棚への切り替えでドロップイベントを失わない構成にする。
- WKWebView全体を受信領域で覆わない。Webページへのファイル添付操作と棚への追加を区別する。
- 現在は一つのBrowserViewを複数ディスプレイ間で移動しているため、棚のデータは共有し、ドラッグ中の別画面展開でビューを奪わない。
- ブラウザの `downloadDidFinish` は既に完成URLを持つため、オプション有効時に `ShelfStore.add(url:)` へ渡せる。

## クイックスイッチ: 実装の分け方

| 候補 | 実装案・判定 | 優先度 |
|---|---|---|
| スリープ抑止 | IOKitのpower assertion。30分／1時間／解除まで。期限・終了時に解放し、残り時間表示 | 最初 |
| 出力ミュート・音量 | Core Audio。既定出力デバイスと書き込み可能なプロパティを確認。非対応機器は理由付きで無効化 | 最初 |
| 接続済み音声出力の切替 | Core Audioで出力先を選ぶ。Bluetooth機器への接続そのものとは別機能 | 次段階 |
| カスタムショートカット | ユーザーが選んだmacOSショートカットをカードから実行。集中モードなどの候補はOSごとに動作確認 | 最初 |
| システムのダークモード | System Eventsのappearance preferencesにdark modeあり。Apple Eventsによる読み書きと許可処理を試作 | 次段階 |
| ロック・スクリーンセーバー | ショートカット等の実行型カード候補。対象OSで利用可能なアクション／起動経路を確認 | 次段階 |
| デスクトップアイコン非表示 | 安定した操作経路を未確定。非公開設定やFinder再起動への依存を初期版に入れない | 保留 |
| AirPodsへ接続 | OS・機種・接続状態による互換性検証が必要。既に接続されたデバイスへの音声切替から始める | 保留 |
| 蓋を閉じたままスリープ抑止 | 通常のidle sleep抑止とは異なる。標準power assertionだけで保証しない | 初期対象外 |
| マイクのミュート | デバイス単位の制御と「全アプリで録音不可」は別。対応範囲を実機確認するまで保証しない | 保留 |

### 技術と状態管理

- `QuickAction` に、識別子、SF Symbol、表示名、実行方式（トグル／一度実行／値変更）、対応状況、現在状態、実行中・失敗を持たせる。
- `KeepAwakeService`: `IOPMAssertionCreateWithName` と解放処理。SDKでは特別な権限不要とされる。`kIOPMAssertPreventUserIdleSystemSleep` と `kIOPMAssertPreventUserIdleDisplaySleep` を区別し、「本体だけ」「画面も維持」を選ぶ。通常のidle sleep抑止は蓋閉じ・明示的スリープ等を防がない。
- `AudioDeviceService`: `AudioObjectHasProperty` / `AudioObjectIsPropertySettable` で対応を調べ、`kAudioDevicePropertyMute` / `kAudioDevicePropertyVolumeScalar` を読み書きする。外部変更・出力先変更を監視し、成功を読み戻してから表示を更新する。
- `ShortcutRunner`: `/usr/bin/shortcuts` を `Process.executableURL` と `arguments` で呼ぶ。名前をシェル文字列へ埋め込まない。対話・許可待ちを扱い、失敗を表示する。ショートカットは単発アクションとして表示し、状態が読めないものに偽のオン／オフ表示を付けない。[Appleのコマンドライン連携](https://support.apple.com/en-ng/guide/shortcuts-mac/-apd455c82f02/mac)
- システム外観を変更する場合、`NSApp.appearance` ではアプリ内の見た目しか変わらない。System EventsへのApple Events送信を別機能として実装し、初回使用時に権限を要求。現在のentitlementsにはない `com.apple.security.automation.apple-events` と `NSAppleEventsUsageDescription` を追加し、署名・公証をやり直す。[Apple entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)、[用途説明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
- 複数操作をまとめるプリセットは、失敗した項目がわかる設計にする。外部で変更されたOS状態を、終了時に古い値で強制上書きしない。スリープ抑止は自分が作ったassertionだけ解除する。

## 開発順序と完了条件

1. **技術試作**: 閉じたノッチへのファイルドロップ、ドラッグ中の展開・取消、他アプリへの受け渡し、画面間移動を先に検証。並行候補としてpower assertionと音量プロパティの読み書きを確認。これは次回実装時の作業であり、今回の調査では実行していない。
2. **第一版**: 外部ファイル参照の棚、複数選択、ピン留め、復元、ダウンロード連携＋スリープ抑止・音量・カスタムショートカット。
3. **第二版**: アプリ生成ファイル／画像／テキストの取り込み、グループ化の拡充、音声出力切替、システム外観。アプリごとの対応状況を明示。
4. **必要なら第三版**: コピー履歴を別途オプトインで追加。機密データ種別・除外アプリ・履歴上限・一時停止・全削除をセットで設計。AirPodsやデスクトップ非表示は個別検証後に判断。

検証はFinder／Safari／Chrome／Mail、ファイル名の重複・日本語・空白、大容量・フォルダ・iCloud未取得・削除済み・外付け切断、再起動、ドラッグ取消、複数画面・Spaces・フルスクリーンを対象とする。OS操作はタイマー解除、終了・異常終了、権限拒否、外部変更、音声デバイス切替を確認する。公開する場合は従来どおりUniversal build・Developer ID署名・Apple公証・公開ZIP再取得検証を行う。

## ローカルで読んだ根拠

- `Sources/NotchBrowser/NotchController.swift`: ホバー開閉、keepOpen、isShowingModal、画面間でのBrowserView移動。
- `Sources/NotchBrowser/BrowserViewController.swift`: WKDownloadの保存先と完了コールバック。
- `Resources/NotchBrowser.entitlements`: 現状はカレンダー用のみ。Sandbox／Apple Eventsのentitlementなし。
- Xcode 26.3内macOS SDK `IOKit.framework/Headers/pwr_mgt/IOPMLib.h`: power assertionの権限、idle sleepと蓋閉じの違い。
- 同SDK `CoreAudio.framework/Headers/AudioHardware.h`: 既定出力・ミュート・音量のプロパティ。
- macOS 15実機の `/System/Library/CoreServices/System Events.app/Contents/Resources/SystemEvents.sdef`: appearance preferencesのdark modeプロパティ。存在確認のみで変更操作は行っていない。

macOS 26以降、ノッチ付き実機でのドラッグ受信、各スイッチの実行は未検証。設計上の候補と実装・動作確認済みの機能を区別する。
