# TASK-NOTCH-020

タスク・議事録の一覧と、開いた詳細本文を Application Support/NotchBrowser の版番号付き JSON に保存する。認証トークンは保存スキーマに含めず、画像 URL は保存前に除く。旧 UserDefaults のタスクキャッシュは破棄し、旧キーも削除する。一覧の表示・保存は新キャッシュでも1000件を上限とする。

タブを開いた場合は前回の成功から60秒未満なら取得を省略する。更新ボタンは常に取得する。タスク差分は last_edited_time/on_or_after に前回成功の1分前を指定する。更新ボタンまたは前回全件取得から24時間で全件照合する。429 は既存 API の再試行処理を使う。

削除された選択項目は一覧の選択を解除し、詳細に「この項目は Notion で削除されました」と表示する。キャッシュ消去や設定変更は削除通知として扱わない。

## DesignPreview 起動

監督側で実行する。全 fixture と引数処理は DEBUG のみ。実ユーザーのキャッシュ・認証は使わない。

```sh
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --notion-connection=connected --select-tab=tasks --cache-state=cached
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --notion-connection=connected --select-tab=tasks --cache-state=refreshing
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --notion-connection=connected --select-tab=tasks --cache-state=failed --cache-tooltip
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --notion-connection=connected --select-tab=meetings --cache-state=cached
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --notion-connection=connected --select-tab=meetings --cache-state=refreshing
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --notion-connection=connected --select-tab=meetings --cache-state=failed --cache-tooltip
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --notion-connection=connected --settings-pane=pinned --pinned-selection=tasks --cache-state=settings
TMPDIR="$PWD/.build/tmp" ./scripts/preview.sh --notion-connection=connected --settings-pane=pinned --pinned-selection=meetings --cache-state=settings
```

`--cache-tooltip` は失敗ツールチップの内容を固定表示する。設定 fixture の最終更新は10月15日1:52。

## 検証

Notch020Tests に差分・全件削除・削除選択・60秒・同時1件・24時間・破棄・版番号・認証非保存・画像URL非保存・取得失敗・議事録更新条件を追加した。

Lead承認のA案により、既存の testBoundedJSONCacheFilterAndFirstSelectionPersist だけを更新した。旧 UserDefaults キャッシュの破棄とキー削除、フィルターと最初の選択の保存、別データソースの新キャッシュを表示しないことを検証する。他の既存テストは979e581から変更していない。

新規の testNewCacheLimitsSavedDisplayedAndFetchedRowsToOneThousand は1005件の保存、復元表示、ページング付き全件取得、既存の過大ファイルの復元で、表示・保存の両方が1000件になることを検証する。testTokenNeverEntersFileAndAllTaskInvalidationConditions はテスト用トークンで取得したキャッシュ見本を一時JSONファイルに書き出し、その内容にトークン文字列が含まれないことと実データが保存されていることをassertする。

監督側の初回 swift test は382件中7件失敗。接続エラー時の Color.clear と showsLoading の既存分岐を復元し、その内側でキャッシュ表示を選ぶよう修正した。DEBUGモックの設定中にキャッシュ破棄で一覧が消える問題は、モックへの破棄処理を抑止して修正した。

この作業では swift test を実行していない。一時ファイルとモジュールキャッシュを worktree 内に指定し、Command Line Tools の macOS 15.5 SDK で変更した製品ファイルを primary-file として DEBUG/Release の型チェックを行う。全体チェックは既存の macOS 26 の Glass API がこの SDK にないため完了できない。テストの型チェックも XCTest モジュールがないため完了できない。監督側で macOS 26 SDK による全体チェック、swift test、プレビューと実画面でのスクロール保持・削除表示の確認が必要。

A案反映後の確認：変更した製品ファイル7件の DEBUG/Release 型チェック、追加・変更したテストの構文解析、git diff --check は成功した。既存テストは承認された1メソッドを除いて979e581と完全一致することを確認した。020プレビュー4状態、ツールチップ固定表示、両タブの設定データ行と上記起動コマンドはソース上で確認した。プレビュー自体の起動と swift test の再実行はこちらでは行っていない。
