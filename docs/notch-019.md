# TASK-NOTCH-019

基準: `f37dce9`（v0.5.43）。commit/push、配布、インストール先の変更は行わない。

## 変更

- 意味検索、EmbeddingGemma 2、モデル取得・コンパイル・fp16・トークナイザー、準備段階表示・再試行、設定の意味検索ページ、永続検索キャッシュと関連テストを削除。
- 議事録検索はタイトルと要約／メモの文字一致のみ。既存の文字一致方式（空白区切りの語の一致率45%以上、1議事録1件・上位20件）を維持し、大文字小文字は区別しない。日付の言い方は通常の文字列として扱う。日付チップと「全期間で探す」を削除。プレースホルダは「議事録を探す」。
- 一致した一文、検索結果行58pt、通常一覧の時刻メタ／検索結果の日付メタ、0件表示を維持。詳細の一致段落へ移動し、1回だけ約2秒保持してフェードする。Reduce Motion時はフェードせず消す。Esc／✕で日付順一覧に戻り、BrowserViewController／NotchPanelのEscフックも維持。
- 起動時に旧 `~/Library/Application Support/NotchBrowser/meeting-search` のみ削除する。対象パスと標準化後のパスの完全一致、ディレクトリ型を検証。対象・祖先・内部にシンボリックリンクがある場合や検証に失敗した場合は削除しない。親・兄弟・別ホーム・遡及パスは拒否する。他のアプリデータは削除しない。DesignPreviewはこの削除処理を呼ばない。
- タブの共通セルは非選択時に背景を描画せず、選択時のみ青を描画。タスク・議事録・エージェントのicon/title/bothで共通。既存018のタブ／本文テストファイルは変更しない。検索ストアを利用する既存検索テストは削除済みモデル依存を外して維持。

## DesignPreview

`--meeting-search` は `list` / `results` / `empty` / `detail-highlight` / `typing` のみ受理する。接続はオフラインモックになり、議事録パネルが開く。preparing系・settings・旧detailは受理しない。`--settings-pane=semantic-search` も削除。

作業ツリーでの起動例（以下は監督側で必要な権限を得て実行する。今回の作業ではGUI起動は実行しない）:

```sh
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --meeting-search=list
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --meeting-search=results
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --meeting-search=empty
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --meeting-search=detail-highlight
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --meeting-search=typing
```

`detail-highlight` は確認用にハイライトを保持する。本番では約2秒後にフェードする。

タブ3形式と選択状態の確認例:

```sh
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --meeting-search=list --tasks=list --agents=list --fixed-display=icon --select-tab=meetings
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --meeting-search=list --tasks=list --agents=list --fixed-display=title --select-tab=tasks
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --meeting-search=list --tasks=list --agents=list --fixed-display=both --select-tab=agents
```

## 検証

本体、DesignPreview、全テストソースの型チェックと `git diff --check` を実施。コンパイラの一時出力・モジュールキャッシュは作業ツリーの `.build` 内に限定する。テスト実行／GUI表示の確認とは区別する。

追加テスト: 削除パス制限とリンク保護、3タブ×3モードの透明／青背景・選択切替、文字一致・日付語の扱い、検索クリア、残したプレビュー状態。既存のハイライト・Reduce Motion・58pt・メタ情報・Esc・再帰本文取得の検索テストを維持。

`swift test` は監督側がサンドボックス外で次の指定コマンドを実行する。今回の続行作業では実行しない。

```sh
TMPDIR="$PWD/.build/tmp" swift test
```
