# TASK-NOTCH-018

## 本文が表示されなかった原因（コード調査）

基準 v0.5.40 / 6d384b2 / build 55。実 API・トークンへはアクセスしていない。

`NotionMeeting.parse` は `meeting_notes.summary` / `notes` / `transcript` を文字列または参照オブジェクトとして読んでいた。しかし対象の応答は `meeting_notes.children.summary_block_id` / `notes_block_id` / `transcript_block_id` に参照を持つ。この形では参照がすべて nil となり、`meeting.sections` が空で、本文取得 GET が呼ばれない。`transcription` も型自体は受理していたが同じ問題を持つ。

さらに詳細画面は取得結果が空のセクションを `visibleSections` で除外していた。API で提供されない文字起こしを含め、Notion と同じ3タブ・空状態を表示できなかった。一つの取得エラーで後続セクション取得も止まっていた。

## 対応

- children 内の3参照を優先して読み、従来の参照形式も互換性のため受理。
- 各参照に GET `/v1/blocks/{id}/children`。既存の `has_more` / `next_cursor` ページングと `has_children` 再帰取得を利用。本文の既存の500ブロック・100リクエスト・深さ6制限を解除し、最後のページまで取得する。循環参照は visited で抑止、反復/欠落カーソルはエラーとして扱い、キャンセル可能にする。
- 共通 HTTP 実装で429の Retry-After（秒値）を待って再取得。ヘッダーなしは1秒・2秒。最大3回、0秒指定でも最小0.25秒待機。
- 3タブを常設、空または取得不可の文字起こしは専用空表示。一つのセクション失敗が他の取得を妨げない。
- 見出し・リスト・読み取り専用チェックボックスは既存本文描画と同じ。引用・区切り・初期閉のトグルを追加。表・画像はブロック位置への「Notion で表示」。
- 文字起こしは話者情報付きブロック、または「時刻 話者：発言」テキストを話者太字・時刻灰色で描画。未知の応答形は通常テキストとして表示。
- 固定ページ順序は全行 UUID 配列で保存、旧設定から順序を補完。設定一覧とタブバーで同じ順序を使用。
- タスク／議事録の初期表示はアイコンのみ。エージェントと同じポップオーバーのアイコン選択と表示選択を共有。

## DEBUG プレビュー

DesignPreview の既存の fixture パス引数に追加する。全例に `--notion-connection=connected` を併用すると、キーチェーンの読み取りも抑止する。以下の組み合わせはモック接続を使用する。

| 対象 | 引数 |
| --- | --- |
| 固定一覧ドラッグ | `--fixed-pages-drag --tasks=settings --meetings=settings --agents=list` |
| タスクの表示 | `--settings-pane=pinned --pinned-selection=tasks --tasks=settings` |
| 議事録の表示 | `--settings-pane=pinned --pinned-selection=meetings --meetings=settings` |
| タブバー3形式 | `--meetings=detail --tasks=list --agents=list --fixed-display=icon`（`title` / `both` も可） |
| 要約 | `--meetings=detail --meeting-section=summary` |
| メモ | `--meetings=detail --meeting-section=notes` |
| 文字起こし | `--meetings=detail --meeting-section=transcript` |
| 空の3タブ | `--meetings=empty-tabs --meeting-section=summary`（`notes` / `transcript` も可） |

新規モック設定と文字列は `#if DEBUG` 内に置く。プレビューは今回起動していない。

## テストと未検証事項

変更ファイル（14）:

- `Sources/NotchBrowser/Settings.swift` / `SettingsView.swift`
- `Sources/NotchBrowser/BrowserViewController.swift` / `NotchTabLayout.swift`
- `Sources/NotchBrowser/NotionTasks.swift` / `NotionTasksView.swift`
- `Sources/NotchBrowser/NotionMeetings.swift` / `NotionMeetingsView.swift`
- `Sources/NotchBrowser/NotionAgents.swift` / `NotionConnection.swift` / `NotionDatabaseMonitor.swift`
- `scripts/DesignPreview.swift`
- `Tests/NotchBrowserTests/Notch018Tests.swift`
- `docs/notch-018.md`

`Notch018Tests.swift` に13件追加。応答形を写した JSON を使い、両型名・children の3参照取得・GET・ページング・再帰・429・空、500ブロック/深さ6を超える本文・欠落カーソル、順序/表示の Codable 保存と旧設定補完、話者/時刻、狭幅省略、モック接続引数と空タブの非接続を確認する。

ユーザー指定によりテスト・ビルド・UI 起動・ネットワークアクセスは実行しない。既存315件と追加テスト、Release のモック文字列除外、実際のドラッグ操作・狭幅の文字省略・ツールチップ・実 API の本文/文字起こし形状は未検証。commit / push / release、指定のアプリへの操作は行っていない。

## 328件のテスト実行結果を受けた修正

ユーザーによるサンドボックス外の `swift test` で328件中3件のアサーション失敗が報告された。こちらでは再実行していない。

### 分離タブのホバー時テキスト

`DetachedTabLayoutTests.testTextHoverAt66KeepsOneCharacterAndEllipsis` の109・110行が失敗。018の固定タブ向け「省略時に1文字だけ残さない」条件を、`TabButtonCell.displayedTitle(forBounds:)` の分離タブ描画にも追加してしまったことが原因。66pt幅・ホバーで閉じるボタンの領域を確保すると「新…」までしか収まらず、追加条件で空文字にしていた。

分離タブ側の追加条件を削除し、従来どおり `DetachedTabLayout.displayedTitle` の結果を直接返す実装へ戻した。分離タブのレイアウト・ホバー・タイトル計算は変更しない。固定タブ側は `NotchTabLayout.displayedTitle` を使い、018の省略要件を維持する。

### エージェント設定のセクション順

`NotionSettingsHotfixTests.testAgentsSettingsMatchesTabSectionOrderWithConnectionGroup` の179行が失敗。共通アイコン設定の導入時に、エージェント設定の既存 `Section("表示")` を共通ビューと `Section("エージェント")` に分割したことが原因。既存の「表示」セクションを探すテストが失敗し、チャット外観・通知も別セクションへ移動してしまっていた。

共通 UI をセクション枠と内部コントロールに分けた。エージェントは既存の `Section("表示")` 内でコントロールを共有し、接続 → Notionで開く → 登録したエージェント → 名前で探す → 表示、というセクション順を保つ。チャット外観・通知も「表示」内に戻した。タスク・議事録の表示グループと共有アイコン選択は維持する。

今回の変更ファイルは `BrowserViewController.swift`、`NotionAgents.swift`、`NotionTasksView.swift`、本書。既存・追加テストの変更は不要で、テストファイルは変更していない。テスト数は328件のまま。修正後のビルド・テスト・UIは未検証。

## 表示コントロールの EnvironmentObject クラッシュ修正

上記修正後の328件全件パスはユーザーが確認済み。その後、DesignPreview を `--notion-connection=connected --settings-pane=pinned --pinned-selection=tasks --tasks=settings` で起動した際に、`EnvironmentObject.error()` → `NotionPageDisplayControls.symbol.getter` → Button のラベル描画で EXC_BREAKPOINT が発生したとの報告を受けた。

共通コントロールの `@EnvironmentObject SettingsStore` が描画時の暗黙の必須依存になっていたことが原因。設定ウィンドウのルートには環境注入があるが、報告された Form 内の描画経路ではコントロールに届いていなかった。こちらでは実機再現していないため、その内部の伝播が途切れた理由は未確認。また、タスク・議事録のタブ内設定の `NSHostingView` はそもそも SettingsStore を環境注入しておらず、同じコントロールを表示すると失敗し得る構成だった。既存テストは共有コントロールを実際に描画していなかった。

対処:

- `NotionPageDisplaySettings` と `NotionPageDisplayControls` を明示的な `@ObservedObject SettingsStore` 引数へ変更。コントロールにデフォルトのストアや環境取得のフォールバックは設けない。
- タスク・議事録の設定ページがストアを保持し、共通コントロールに渡す。ページの初期化引数はストアを注入可能にし、本番と DesignPreview の既存呼び出しでは `.shared` を使用する。
- ［設定 › 固定ページ］とタブ内設定はいずれも同じ設定ページを使うため、環境注入の有無に依存せず表示できる構成へ変更。
- エージェントも既存ページの設定ストアをコントロールに直接渡す。「表示」セクション順は維持。

`NotionDisplayHostingTests.swift` に3件追加。隔離 UserDefaults のストアを使い、タスク・議事録・エージェントそれぞれの共有コントロールを、環境注入ありの `NSHostingController`、環境注入なしの `NSHostingView`、既存セクション内・暗色ウィンドウの `NSHostingController` でレイアウトしてメモリ内へ描画する。ライブの Notion ストア・トークン・ネットワークは使わず、画像や証拠ファイルも保存しない。テスト対象は表示コントロールとホスト構成であり、設定ページ全体・ブラウザ全体の操作テストではない。

今回の変更ファイルは `NotionTasksView.swift`、`NotionMeetingsView.swift`、`NotionAgents.swift`、新規 `Tests/NotchBrowserTests/NotionDisplayHostingTests.swift`、本書。既存テストは変更していない。予定テスト数は331件。こちらでは制約に従いビルド・テスト・DesignPreview 起動を実行しておらず、修正後のクラッシュ解消は未検証。

## Designer 修正：固定タブのタイトル幅・両方表示・一覧メタ情報

表示コントロール修正後の331件全件パスはユーザー確認済み。今回の変更はタスク・議事録・エージェントの固定タブ表示と議事録一覧のメタ文字列に限定する。

固定タブの幅を NSButtonCell の cellSize、文字の描画幅をその titleRect に依存させていたため、「両方」や短いタイトルでも必要な横幅を確保できない構造だった。固定 Notion タブだけに表示モードを保持し、同じ設定処理・実測幅・明示的な横配置で描画するよう変更した。

- 「両方」は18ptアイコン、4pt間隔、その右にタイトル。「タイトル」はアイコンを表示しない。
- 自然幅は左右余白12pt＋アイコン領域22pt（必要な場合）＋文字の実測幅。文字幅を切り上げ、上限はタブ全体で120pt。タスク・議事録・Notion は自然幅で省略せず表示する。
- 120ptを超える長いタイトルは末尾「…」、ツールチップは全文。他の固定ページを先に圧縮し、3つの Notion 固定タブの自然幅を確保する。3タブだけでも固定グループの領域に収まらない極端な狭幅では既存の配分に戻し、省略後1文字しか残らない場合は文字を出さない。グループ全体の幅上限は維持する。
- 分離タブは既存の描画分岐・幅計算・ホバー省略を使用し、分離時のアイコン位置設定も従来どおり。通常のブラウザタブは変更しない。
- 議事録行メタ情報を一つの文字列にし、「11:04・45分・3人」の形に統一。所要時間が不明なら「11:04・3人」とする。

`NotionTabBarDesignerTests.swift` に4件追加。タイトル実測幅と120pt上限、「両方」のアイコン＋全文タイトルの設定とメモリ内描画、「タイトル」の短い名前の全文表示／長文省略／ツールチップ／狭幅非表示、議事録の区切りと所要時間欠落を確認する。既存テストは変更していない。予定テスト数は335件。

変更ファイル：`BrowserViewController.swift`、`NotchTabLayout.swift`、`NotionMeetings.swift`、`NotionMeetingsView.swift`、新規 `Tests/NotchBrowserTests/NotionTabBarDesignerTests.swift`、本書。ビルド・テスト・DesignPreview 起動は今回も未実行。実際のウィンドウ幅での表示確認、追加テスト、既存分離タブの回帰確認は未検証。

## Designer 修正：固定アイコンのサイズと圧縮順序

上記335件全件パスはユーザー確認済み。「両方」で他の固定ページのアイコンが縮小されるとの報告を受け、固定タブ全体の圧縮を修正した。前回は Notion タブの自然幅を優先し、残りの固定ページをアイコン用の最小幅なしで圧縮していた。さらにそれらの画像描画を NSButtonCell に任せていたため、小さなタブ幅に合わせてアイコンも縮められる構造だった。

- 全固定ページに明示的な描画サイズを使用する。一般の固定ページは従来の16pt、Notion 固定タブは従来の18ptで、表示設定や利用可能幅により変更しない。「タイトル」で非表示になるアイコン以外は常にこのサイズで描画する。
- 各タブのアイコン用最小幅を保持し、最初にタイトル領域を圧縮する。省略後1文字しか残せない場合は文字を表示しない。
- 全タイトルを最小領域まで圧縮した後で、4ptのタブ間隔を0ptまで詰める。
- 間隔0ptでも収まらない場合、アイコン幅を維持した文書を固定タブ用の横スクロール領域に入れる。通常のタブ用スクロールとは別に操作でき、領域が広がれば元の固定グループ構成に戻す。
- 表示に必要な余裕があるときは自然幅と4pt間隔へ戻る。Notionの120pt上限・タイトルモード・議事録メタ情報の「・」を維持。分離タブの描画・圧縮処理は変更しない。

`FixedTabCompressionTests.swift` に5件追加。タイトル→間隔→スクロールの段階、全設定モード・複数幅で一般固定アイコン16ptとNotionアイコン18ptを維持する描画、スクロール領域への移行と復帰を確認する。既存テストは変更していない。予定テスト数は340件。

変更ファイル：`BrowserViewController.swift`、`NotchTabLayout.swift`、新規 `Tests/NotchBrowserTests/FixedTabCompressionTests.swift`、本書。制約に従いビルド・テスト・プレビュー起動は未実行。実ウィンドウでの画像サイズ・トラックパッド/スクロールバー操作・追加テスト・分離タブの回帰確認は未検証。

## 960ptプレビューの「両方」タイトル消失・サイズ不統一修正

340件全件パスはユーザー確認済み。960ptプレビューでタイトルが消えた原因は、(1) 固定ページを表示中も通常タブの自然幅（最大150pt）を予約し、(2) アイコン最小幅からの追加領域を均等配分して全タイトルを数ptまで削ったこと。ウィンドウの右側の余白は、カメラ領域とツールバーを挟んだ別領域で、従来の左タブバー計算には含まれない。画像サイズも一般16pt／Notion18ptと意図的に分けてしまっており、今回の全タブ同サイズ要件に一致しなかった。

実際の制約から幅を求める `fixedTabBudget` を本番で使用する。960pt・中央から-110pt・左14pt・追加ボタン28pt・間隔4ptではタブバー幅は324pt。固定ページ表示中は通常タブの予約を28ptとし、固定グループに296pt使う。通常ブラウザ表示中の予約は従来どおり。カメラ上へタブを配置したり右ツールバーへ重ねたりしない。

タイトル圧縮は長いタブから行い、Notion／タスク／議事録は120pt上限内の自然幅を確保する。ほかのタイトルを省略しても不足する場合は間隔を詰め、それでも不足すれば横スクロールする。スクロール移行・選択変更後は選択中の固定タブを可視領域へ出す。タイトルがなくなるほど各タブを均等に削る処理は使用しない。

本番の3タブの構成処理は明示的に16ptを渡し、一般固定ページと描画・幅計算を統一する。既存テストが直接利用する旧ヘルパーと設定メソッドの18pt既定値は互換性のため保持するが、本番経路では使用しない。分離タブ・議事録の「・」は変更しない。

`FixedTabActualBudgetTests.swift` に2件追加。実装と同じ960pt→324pt→296ptの予算計算、プレビューと同じ7タブの幅配分後に3タイトルが全文で描画されること、本番設定の全モードでアイコン16ptを確認する。既存テストは変更していない。予定342件。こちらではテスト・ビルド・プレビューを実行しておらず、追加テストと実際の画面・スクロールの確認は未検証。

変更：`BrowserViewController.swift`、`NotchTabLayout.swift`、新規 `FixedTabActualBudgetTests.swift`、本書。
