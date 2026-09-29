# One Switchの調査とクイックスイッチへの反映

> 履歴資料: 以下はv0.4.0時点の調査・実装。クイックスイッチはユーザーの方針変更によりv0.4.1で削除した。現在の機能一覧ではない。

調査日: 2026-09-29。対象はFireball StudioのMac用One Switch。ウィンドウ切替アプリの同名製品やOnly Switchとは区別した。

## 確認した資料

- [公式製品ページ](https://fireball.studio/oneswitch): デスクトップ非表示、外観切替、起動保持、スクリーンセーバー、ヘッドホン接続。公式掲載画像を確認し、アイコン・機能名・現在の状態を同時に示す操作を参考にした。画像やアセットはアプリへ転用していない。
- [公式ダウンロード](https://fireball.studio/oneswitch/download): 配布DMGを読み取り専用でマウントし、Info.plistで **1.35.4 / build 440 / macOS 12以降** を確認。英語ローカライズの機能名・設定項目も照合した。インストール、ライセンス認証、競合アプリでのシステム操作は行っていない。リソース上の項目がすべてのOSで動くとは扱わない。
- [Setapp掲載情報](https://setapp.com/apps/one-switch): 不要なスイッチを隠すカスタマイズを確認。掲載バージョンとOS条件は公式配布物と食い違うため、最新版の根拠には使わない。
- [公式案内先のReddit](https://www.reddit.com/r/OneSwitch/): ヘッドホン以外の音声機器追加、Background Sounds、HDRなどの要望、マイク、解像度、Stage Manager、helper権限に関する報告を確認。個人の報告であり、発生率や全環境での再現を示すものではない。
- [公式X](https://x.com/fireball_studio): 直接取得を試したが取得できなかったため、投稿本文を確認済みとは扱わない。

公式サイトだけでは機能全体が見えにくいため、配布物の表示項目まで確認した。単なる機能数の増加に加え、現在の状態と失敗を正しく伝えることを重視する。

## 対応表

| One Switchの機能・操作 | 今回のNotchBrowser |
|---|---|
| デスクトップアイコン非表示 | カードから切替。Finder設定を更新してFinderを再起動。ファイル自体は変更しない |
| ダークモード | System Eventsのappearance preferencesで切替。初回はmacOSのオートメーション許可が必要 |
| スリープ抑止 | 15/25/30/60/120分・無期限。画面の点灯維持は別に選択。終了時に自分のIOKit assertionだけを解放 |
| 蓋を閉じたままの動作 | 対象外。通常のアイドルスリープ抑止と区別して表示 |
| スクリーンセーバー | macOSのScreenSaverEngineを開始 |
| 画面消灯 | macOSのpmset displaysleepnow。自分の点灯維持を先に解除 |
| Dock非表示 | Dockの自動非表示を切替 |
| 隠しファイル表示 | Finderの表示設定を切替しFinderを再起動 |
| マイクミュート | Core Audioの既定入力機器の書込可能なmuteを操作。非対応の機器では無効表示 |
| ヘッドホン接続 | 接続済み音声機器の出力切替を実装。未接続のBluetooth機器の接続・ペアリングはBluetooth設定へ |
| 音声操作 | スピーカーミュートと連続操作の音量スライダー。出力変更後に再取得 |
| 通信 | Wi-Fi電源をCoreWLANで切替。機器がない場合は無効表示 |
| カスタマイズ | カードを非表示・並び替え。選択は再起動後も保持 |
| ショートカット | macOSショートカットを複数の実行カードとして登録可能。削除・改名されたものは実行不可表示 |
| 集中モード | システム設定へのリンク。自作ショートカットも登録できる。専用トグルとは表示しない |
| Night Shift / True Tone / 解像度 | ディスプレイ設定へのリンク。未検証のprivate frameworkで直接変更しない |
| 低電力 / 高電力 | バッテリー設定へのリンク。管理者helperは追加しない |
| 音楽再生 | 対応するmacOSショートカットを登録する方式。専用メディア操作は追加しない |
| Screen Clean / Lock Keyboard / Lock Screen | 今回は対象外。安全な入力復帰と全画面・権限を含む別の検証が必要 |
| ウィジェット非表示 / Stage Manager | 今回は専用トグルなし |
| 日の出・日の入りでの外観予約 / スイッチごとのグローバルホットキー | 今回は追加しない |

## UIと状態遷移

ノッチを開いた右上にSF Symbolsのswitch.2ボタンを追加。クリックすると別ウィンドウを出さず、同じパネルのブラウザ領域全体をカード一覧に切り替える。ノッチの形と上部のカメラ用余白を保ち、背景・枠に既存のGlassSurfaceを使う。

カードにはアイコン・名前・状態を表示し、有効なトグルは青とチェックの両方で表現。単発操作は再生／電源アイコンにして区別する。操作アイコンはすべてSF Symbols。絵文字は使わない。

「ブラウザ」、右上アイコン、Esc、タブ選択で戻る。棚のファイルを保持しながらスイッチ表示中は棚を隠し、ブラウザへ戻ると復帰。ノッチを閉じた際にはスイッチ画面を終了し、ファイルがあればコンパクトな棚を残す。

音量・ミュート・音声機器・Wi-Fi・外観等はOSから読み直し、保存した見かけのON/OFFを使わない。実行失敗はメッセージで表示。非対応の機器を成功扱いにしない。抑止タイマーは画面を閉じても継続する。

## 実装資料

- [IOPM assertion types](https://developer.apple.com/documentation/iokit/iopmlib_h/iopmassertiontypes)
- [Core Audioの既定音声出力](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultoutputdevice)
- [Apple Eventsの利用目的](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)

## 検証範囲

32件の自動テストが成功。追加したテストでは、スイッチ全体表示・棚の復帰・閉じた際の遷移と、スリープ抑止の期限・モード切替・解除を確認した。独立したPreviewアプリで表示、スリープ抑止カードのオン／オフ、表示項目の編集・保存、並び替え・保存、右上アイコンからブラウザと棚への復帰を確認した。

ネットワーク切断、Finder再起動、画面消灯、スクリーンセーバー、macOS権限が必要な切替はこの作業中にユーザーの環境へ実行していない。Bluetooth全機種、Intel実機、macOS 26での動作を検証済みとはしない。
