# TASK-NOTCH-TAB-SETTINGS-015

ベース: 760fdfa / v0.5.37。

タスク・Notion エージェントの右上の歯車から、同じタブの設定に切り替える。「‹ 戻る」で一覧に戻る。設定はアプリ設定と同じ grouped Form の「接続」「データ」「表示」。接続のリンクはアプリ設定の Notion セクションを開く。トークン入力はそこだけで行う。

案A: Notion の接続確認済みの場合だけタブを表示する。表示ルールは `NotionTaskRules.tabVisible(connected:)` に集約。URL の確認状態はデータ読み込み用の `available` に残し、タブ表示には使わない。エージェント機能の有効・無効設定も引き続き尊重する。URL 未設定のタスク、エージェント未登録では空状態から「設定を開く」でタブ内設定へ進む。切断時は両方のタブを外し、パネル表示前の通常タブの選択を復元する。切り離した単独タブのウインドウには固定タブを追加しない。

保存キー `notionTasks.configuration`、`notionTasks.filter` と既存のエージェント設定は継続使用。タスク設定の既定フィルタと一覧のフィルタは同じ保存値を使う。担当者なし、期限グループ、行レイアウト、読み取り専用の状態アイコンは維持。

## DesignPreview（DEBUG のみ）

利用者側で実行:

```sh
./scripts/preview.sh --tasks=tab-settings
./scripts/preview.sh --tasks=unconfigured
./scripts/preview.sh --agents=settings
./scripts/preview.sh --tasks=tab-settings --compact
```

`tab-settings` は確認済みのタスク設定、`unconfigured` は接続済み・URL未設定の空状態、`agents=settings` はエージェント設定を直接表示する。従来の `--tasks=settings`、`--tasks=sources`、`--tasks=settings-error` もタブ内設定を開く。DesignPreview は独立したアプリIDで、タスクモックは保存やAPIアクセスをしない。

## 検証

015 r2: タスクの歯車はフィルタ行の更新ボタンの右に8pt間隔で配置し、専用行を削除。エージェントも更新操作の右に配置。未設定の空状態では右上を維持。空状態はメッセージとボタンの間隔を12ptとし、「確認」と共通の幅・ボタンスタイルを使用する。エージェント設定の「Notionで開く」「登録したエージェント」「名前で探す」は独立した grouped Form セクションに変更し、区切り線だけの行を削除。「ベース URL」は折り返さず、例は入力欄のプレースホルダーへ移動。エージェント設定でもタブのテーマ色を維持する。レイアウト変更のため既存の動作テストは維持し、新規テストは追加していない。ビルド・テスト・GUI検証は未実行。

タブ表示ルール、URL未設定・タスク設定のモック、接続解除による両タブの削除と直前の通常タブへの復帰をテストに追加。既存のタブ表示テストには独立した接続モックを注入し、キーチェーンを変更せず確認できるようにした。

この作業では swift test・ビルド・GUIプレビューを実行していない。利用者側でサンドボックス外の swift test と上記プレビューを実行する。commit/push は行っていない。

### 263件実行後の3件の失敗への修正

`BrowserToolsTests.testSettingsRefreshKeepsNotionPanelVisible` と `HoverBehaviorTests.testHotkeyOpenAndReturnShareNonactivatingFocusAndPreserveContent` に接続済みの独立したモックを追加。案Aでは機能が有効なだけではタブを表示しないため、既存テストにも接続の前提が必要。設定更新時のパネル表示・不透明背景・外観、および012の非アクティブ化・フォーカス・コンテンツ保持の検証はそのまま維持。

切断テストでは `updateChrome` が通常タブのボタンを再作成するため、削除済みのボタンを保持せず、同じタグとアクセシビリティラベルの現在のボタンを取得する。切断前の非選択、切断後の同じタブへの復帰、両Notionタブの削除に加えて、選択中のタブが1つだけであることも検証する。アプリの動作を変えてテストを通す変更は行っていない。修正後の swift test は未実行。

### 015 r3

空状態ボタンの固定幅を外し、自然なテキスト幅で「設定を開く」を省略せず表示する。bordered / regular は「確認」と共通のまま。接続設定リンクには明示的なアクセント色を指定し、エージェントの本文色の継承による黒表示を防ぐ。

説明配置は履歴 d75adae と SettingsView の左揃え VStack（spacing: 2）による主行・補足文の組み方を確認し、エージェント有効化トグルと説明を同じ VStack にまとめた。説明はアイコンの下からトグル直下へ移動。操作・保存の挙動と既存テストは維持。git diff --check は成功。ビルド・テスト・画面確認は未実行。
