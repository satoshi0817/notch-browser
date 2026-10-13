# TASK-NOTCH-013

Notion のタスクを表示する読み取り専用パネル。既存の Keychain token を共有し、database の取得後に data source の query を呼ぶ。タスクの状態変更やページ編集の API は呼ばない。POST は `/data_sources/{id}/query` の検索だけ。

設定は Notion → タスク。状態・期日・担当者は型から自動選択し、「プロパティの設定」で再指定できる。Internal Integration は人間のログインユーザーを識別できないため、「自分の担当者名」をこの詳細設定で選択する。担当者名を読めない場合、担当者表示と自分の担当フィルタを隠す。

一覧キャッシュは UserDefaults の `notionTasks.cache.v1` に JSON として保存し、最大1,000件、現在の URL/data source の1スナップショットだけを保持する。接続変更時は破棄する。本文や期限付き画像 URL はキャッシュせず、詳細を開くたびに再取得する。

## スクリーンショット用プレビュー

既存の `scripts/preview.sh` は独立した DesignPreview アプリを作成する。プレビューのコンパイルに `-D DEBUG` を追加し、タスクのモックを利用できるようにした。通常の release ビルドではモック分岐をコンパイルしない。

利用者側で次のコマンドを実行できる（実装作業中には実行していない）。

```sh
./scripts/preview.sh --tasks=list
./scripts/preview.sh --tasks=detail
./scripts/preview.sh --tasks=detail --compact
./scripts/preview.sh --tasks=empty
./scripts/preview.sh --tasks=no-people
./scripts/preview.sh --tasks=no-body
./scripts/preview.sh --tasks=loading
./scripts/preview.sh --tasks=error
./scripts/preview.sh --tasks=settings
./scripts/preview.sh --tasks=sources
```

`list` は期限切れ・今日・これから・期日なしと完了タスク、`detail` は本文、`empty` は未完了0件、`no-people` は担当者非表示、`no-body` は本文なし、`loading` は30秒間の本文スケルトン、`error` は共有エラーを表示する。`settings` は確認成功、`sources` は複数データソースの設定画面。`--compact` は一覧に詳細を重ねる幅を使う。

DEBUG アプリの実行ファイルに環境変数 `NOTCH_TASKS_MOCK=<状態>` を渡す方法もある。モックの設定やフィルタの操作はタスク用の保存設定へ書き込まず、タスク API を呼ばない。通常アプリで他機能も含めたオフライン確認をする場合は、独立した DesignPreview を使う。

## 既知のキャッシュクラッシュ

`testCompletedThreadKeepsPollingUntilReplyAppearsEvenWhenHistoryOmitsIt` は同じ `NotionAgentsCache` を2つの `NotionAgentsStore` に渡し、片方の `start()` が開始するポーリングともう片方の非同期 refresh が重なりうる。Store も Cache も actor に隔離されておらず、元の実装は Swift Dictionary を同期なしで read/modify/write し、同時に JSONEncoder で走査していた。`rememberThreads` の辞書アクセス付近の例外と整合するデータ競合がある。

Cache の全公開操作を `NSRecursiveLock` で保護し、マージ・所有者更新・JSON 保存を1つのクリティカルセクションにした。読み取りも同じロックを使う。再帰ロックはマージ内部から読み取りメソッドを呼ぶために必要。並行更新後のスレッドとメッセージの全件保持・再読み込みを確認する回帰テストを追加した。元の例外を実行して再現したわけではなく、今回のビルド・テストは利用者側で実行する。

## 検証

`NotionTasksTests` に URL、型マッピング、期限グループと同一期日の編集降順、フィルタ、タブ条件と初回選択、404/ページURLの区別、本文の描画モデル、複数データソース、API の GET/query のみ・ページネーション・ネスト・詳細再取得、429 再試行、キャッシュ上限・設定永続化・並行アクセスのテストを追加。

最初のビルド試行はサンドボックス制限によりコンパイラの型チェック開始前に失敗。その後は利用者の指定どおり、ビルド・テスト・承認が必要なコマンドを実行していない。バージョン変更、commit、push、公証、release は行っていない。
