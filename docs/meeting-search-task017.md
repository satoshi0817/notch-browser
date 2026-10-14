# TASK-NOTCH-017 議事録の意味検索

ベース v0.5.41 / build 56（24a4241、018出荷済み）。commit / push / release、インストール済みアプリの変更、Notionへの書き込み、トークンの取得・表示、権限ダイアログの操作は行っていない。

検索欄は入力停止300msで検索する。通常の日付グループ一覧は018のrowMetadataで `1:41・45分・3人`、検索結果は `9/11・45分・3人`。結果は最大20件、スコア0.45以上、同じ議事録は最も近い一文を表示する。検索中は日付見出しを表示しない。クリア✕はフィールド内の右端に重ね、右余白を常に予約するため入力しても幅は変わらない。Escまたは✕で検索語・期間・結果をクリアし、元の日付順一覧へ戻る。設定の最終更新はja_JP / グレゴリオ暦 / `M月d日 H:mm`形式。

詳細の一致段落は選択ごとに1回だけ強調する。`MeetingMatchHighlightState`はidle→holding（2秒）→fading（1.2秒）→dismissedの状態機械。Reduce Motion時はholding→dismissedで即時に消し、フェードさせない。途中で詳細を閉じるとタイマーをキャンセルする。プレビューdetail / detail-highlightは静的保持。

## r3 Esc・フォーカス・検索結果行

既存のEsc経路は、NSSearchFieldのcancelOperation→BrowserViewController.dismissOverlay、またはNotchPanel.cancelOperation→onCancel→dismissOverlay。dismissOverlayは表示中の議事録タブを先に閉じていた。SwiftUIのonExitCommandだけでは、first responderがウィンドウ・WebView・別のコントロールのときに検索解除を保証できない。

ブラウザごとのMeetingSearchEscapeControllerを議事録ビューと共有する。MeetingSearchEscapeRulesは「議事録タブが表示中、かつ検索語が空でない（空白のみも含む）または結果がある」を判定する。NotchPanel.sendEventはkeyDown/keyCode 53をレスポンダーへ渡す前に検索解除フックに渡す。cancelOperationとdismissOverlayでも同じ判定を先に実行する。検索解除時は入力・期間・結果・一致選択と実行中の検索をクリアし、議事録タブを開いたまま日付順一覧へ戻す。次のEscや検索中でないEscは既存のdismissOverlayへ流す。SwiftUI側のonExitCommandにも既存動作へのフォールバックを設けた。

NotchPanel.canBecomeKey / canBecomeMainは元からtrueであり、DesignPreviewにもkey不可の専用ウィンドウはない。パネルはborderless / nonactivatingPanelで、通常のAppKitキー取得と最初のクリック受付に依存していた。becomesKeyOnlyIfNeeded=falseを明示し、議事録用HostingViewにneedsPanelToBecomeKey=true / acceptsFirstMouse=trueとクリック時のmakeKeyを追加した。検索欄の装飾用の枠線overlayもallowsHitTesting(false)とし、非表示のクリア✕もhit testingから外した。装飾が入力クリックを遮らず、非アクティブパネルでも同じクリックをSwiftUIへ渡す意図の修正である。デザイナーの実機でクリック不良の根本原因を再現・確定したわけではなく、AX/クリック/キーボードでの再確認は必要。アプリを強制activateする処理は追加していない。

検索結果行は58pt、題名・メタデータと一致文の間は3pt。2行のVStack全体を上下中央に置き、題名の行だけに36ptの高さを付けていた構造を除いた。MeetingSearchRowLayoutに高さと間隔を定数化した。通常の日付グループ一覧は従来通り36ptの1行。

## r2の018統合状況

監督側でHEADを24a4241へfast-forwardし、stash popした後の競合をファイル編集のみで解消した。NotionMeetingsView.swiftは018の本文タブ・空本文案内・セクションごとの取得失敗処理・toggle/quote/表/画像/文字起こし表示を維持し、検索の移動と強調を加えた。折りたたみの中にある一致段落では祖先toggleだけを開く。NotionTasks.swiftは018のspeaker/timestampと017のeditedを両方保持した。自動マージされたNotionMeetings.swiftのrowMetadataの重複も除去した。コンフリクトマーカーは残していない。

タブバー本体、NotchTabLayout、固定ページ設定・並べ替え、DesignPreviewは24a4241から変更していない。017による強制iconOnly指定は撤回済み。018の `--fixed-display=icon|title|both` と `--fixed-pages-drag` をそのまま使える。SettingsViewの差分は意味検索ページとDEBUG用のページ選択引数だけであり、018の表示設定・固定ページ並べ替えは維持した。018の既存テストは変更していない。git add / commit / stashの操作も行っていないため、Gitのindexは監督側がstageするまでUU表示のままになる。

検索専用のNotion APIは追加せず、`NotionMeetingsStore.blocks`を通じて018と同一のmeetingBodyを使う。meeting_notes.childrenのsummary_block_id / notes_block_id / transcript_block_idを読む。018の本文取得（全ページ、再帰、重複cursor検査、キャンセル、共通requestの429リトライ）を採用し、旧本文取得の件数・深さ制限を除いた。検索インデックスはこの経路で得るsummaryとnotesのテキストだけを取り込む。

先月・今月・先週・今週・指定月（年指定も可）を先に解析し、calendar_event / calendarの開始時刻に対して開始含む・終了含まない範囲で絞る。recordingやcreatedの時刻は期間判定に使用しない。チップの✕と空結果の「全期間で探す」は日付表現を取り除いた検索語のまま再検索する。

notes_readyの要約・メモだけを文に分割して保存する。画像・文字起こしは取り込まない。キャッシュは文章・ブロック位置・256次元ベクトル・親と子の最新編集時刻・モデル名/リビジョン・次元・文書/検索prefix・最終更新を記録する。モデル情報が変わったキャッシュは利用せず再構築する。取り込み時は分丸めやnotes_readyへの遷移、子編集を見逃さないよう本文を再取得し、文章と編集時刻が一致するベクトルだけを再利用する。取得失敗した本文の古い検索結果は除去する。切断・データ設定変更・キャッシュ消去時も除去する。

モデルは同梱せず初回取得する。埋め込み生成はMeetingEmbeddingProviderで抽象化し、テストはフェイクのみを使用する。準備・取り込み中やモデルエラーでは文字一致検索を使用する。macOS 15未満では常に文字一致検索となり、準備の行を出さない。

## 固定モデルと検証

ユーザーが公開Hugging Face APIで確認した値を `MeetingModelManifest` に設定した。リポジトリは `FluidInference/embeddinggemma-2-coreml`、固定リビジョンは `3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4`。URLは `https://huggingface.co/FluidInference/embeddinggemma-2-coreml/resolve/<revision>/<path>`。取得するのは次の6ファイルだけで、Audio / Vision / position_embeddingsは取得しない。

| パス | バイト数 | 検証値 |
| --- | ---: | --- |
| EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel | 7323423 | SHA-256 `0df9aca02807cf490db6d4f1c68607a8c7f486ad23b376d1968fd3be5eb14677` |
| EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin | 276815424 | SHA-256 `75b97ab036ca87eae60560c4034a63d604201498dc4b6f6971dd0b1e4558d61f` |
| EmbeddingGemma2Text.mlpackage/Manifest.json | 617 | SHA-256 `83eace80b69b46f8415af620ba1b40d7c490d00f7c00ba9dedd2e29da6e9ac19` |
| embeddings.bf16 | 268435456 | SHA-256 `56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877` |
| tokenizer.json | 32170510 | SHA-256 `4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4` |
| config.json | 2845 | SHA-256 `30668aba89f54a200a3fa38913f21e2a2f18aba7215de67c1806542a75b9629b` |

全6ファイルで、ダウンロード後の内容SHA-256とサイズを固定値に照合する。HTTPヘッダーのetag等をハッシュとして扱わず、git blob SHA-1の検証経路は廃止した。大きいファイルはストリームで検証し、検証成功後に置き換える。キャッシュ済みファイルにも同じ検証を行い、コンパイル前に全ファイルを再検証する。不一致のファイルは削除してその準備処理を失敗させ、読み込まない。position_embeddings.f16は今回のテキスト推論の入力に使用しないため取得対象に含めない。

## 推論経路

`tokenizer.json` に書かれたBPE語彙・マージ順位、byte fallback、normalizer、pre_tokenizer、added_tokens、TemplateProcessingを読み取る。BOS/EOSの追加位置はファイルのテンプレートに従う。BOS=2 / EOS=1 / PAD=0。特殊トークンを含め最大512トークンに切り詰め、トークン数以上の最小の固定長（32 / 48 / 64 / 128 / 256 / 512）を選び、`MLModelConfiguration.functionName = embed_<S>` で読み込む。

`embeddings.bf16` をメモリマップし、262144行×512次元のlittle-endian BF16からトークンIDの行を取り出す。値を√512倍してfp16に変換し、`inputs_embeds [1,S,512]` と `attention_mask [1,S]`（実トークン1・右パディング0）を渡す。パディングにはPAD=0の行を使う。読み込む関数の入出力shapeと入力dtypeを検証する。出力 `embedding [1,768]` の先頭256次元を取り、L2再正規化する。

文書prefixは `title: none | text: `、検索prefixは `task: search result | query: `。キャッシュのメタデータにはモデル名・リビジョンを別フィールドで記録し、次元と両prefixも記録する。旧リビジョンなしのキャッシュは再構築する。

## 残る未検証事項

この作業では実ファイルの取得・実モデルのコンパイル・推論を行っていない。固定値とモデル仕様はユーザーからの情報に基づく。実tokenizer.jsonとのトークン列の完全一致は未検証。対応外のnormalizer / pre_tokenizer / post_processorを検出するとエラーとして文字一致検索へ戻す。対応外の処理を無視して近似ベクトルをキャッシュすることはしない。実機の意味検索品質、閾値0.45、ダウンロード・コンパイル・各関数の推論、スクロールと画面表示も未検証。

## 7状態のDEBUG起動コマンド

以下はユーザーが外部で実行するためのコマンド。この作業ではGUI起動やプレビュー用スクリプトは実行していない。すべて専用defaults suiteと接続モックを指定し、モデル・キャッシュ保存・Notion APIを利用しない。固定値と文章のモックは `#if DEBUG` 内に限定する。

```sh
# 1 検索前の一覧
./scripts/preview.sh --defaults-suite=task017-list --notion-connection=connected --select-tab=meetings --meeting-search=list
# 2 一致文と日付チップ付きの結果
./scripts/preview.sh --defaults-suite=task017-results --notion-connection=connected --select-tab=meetings --meeting-search=results
# 3 期間内0件と全期間で探す
./scripts/preview.sh --defaults-suite=task017-empty --notion-connection=connected --select-tab=meetings --meeting-search=empty
# 4 一致段落に移動した詳細（プレビューでは強調を保持、detailも同じ動作）
./scripts/preview.sh --defaults-suite=task017-detail --notion-connection=connected --select-tab=meetings --meeting-search=detail-highlight
# 5 準備中・12/48件
./scripts/preview.sh --defaults-suite=task017-preparing --notion-connection=connected --select-tab=meetings --meeting-search=preparing
# 6 設定の意味検索ページ
./scripts/preview.sh --defaults-suite=task017-settings --notion-connection=connected --meeting-search=settings --settings-pane=semantic-search
# 7 入力済み（欄内✕とフィールド幅の確認用）
./scripts/preview.sh --defaults-suite=task017-typing --notion-connection=connected --select-tab=meetings --meeting-search=typing
```

追加引数は `--meeting-search=list|results|empty|detail|detail-highlight|preparing|settings|typing` と `--settings-pane=semantic-search`。Releaseではモック引数・モック文章を含めない。日付チップの月は実行日の先月となる。準備中状態はmacOS 15以上で表示する。各コマンドに `--fixed-display=icon` / `title` / `both` を追加して018と同じタブ表示モードを検証できる。DesignPreviewの起動ルートと引数の対応、DEBUGコンパイルは確認済み。GUI起動・画面確認は未実施。

## 検証

初回実装では32テスト追加（既存315 + 32 = 347件）。ユーザーがサンドボックス外で `swift test` を実行し、347件全件パスを確認したと報告済み。この結果は今回のモデル仕様の修正前の状態についてのもの。

モデル仕様への対応で7テスト追加し39件となり、r2ではさらに10件を追加してMeetingSearchTestsは49件。新規テストは全ファイルのSHA-256ピンとサイズ、Escの状態遷移、全期間解除後の再入力、ハイライトの状態遷移とReduce Motion・タイミング、日本語の最終更新、通常/検索のメタデータ、全DEBUG状態、childrenのブロックIDと018のページネーション・再帰による本文取り込みを確認する。既存のストリーム検証テストには不一致ファイルの削除を追加した。埋め込み生成は引き続きフェイクで、実モデルは取得しない。

018統合時に、祖先toggleのみの自動展開とspeaker/timestamp/子編集時刻の共存について2テストを追加した。r3はEscの優先判定、ブラウザごとの状態分離と解除、ウィンドウフォーカス時のkey code 53と次のcancelOperationへのフォールバック、結果行の高さ・間隔について4テスト追加。MeetingSearchTestsは55件、既存018の342件と合わせて予定397件。これはソース上のテストメソッド数であり、実行結果ではない。018の既存テストは変更していない。

018統合後に指定の `TMPDIR="$PWD/.build/tmp" swift test` をサンドボックス内で試行した。マニフェストコンパイル時にワークツリー外の `/Users/satoshisuzuki/.cache/clang/ModuleCache` への書き込みが拒否され停止した。r3の397件の全件パスも未確認。承認要求・ネットワーク・サンドボックス外での実行は行っていない。

SDKとモジュールキャッシュを明示し、ワークツリー内の `.build` だけを出力先としてSwiftコンパイラでアプリコードをDEBUG・Release両方で型チェックした。テストコード全件もXCTestのSwiftオーバーレイを指定して型チェックした。いずれも成功。これはswift testの実行結果ではない。

r3もDEBUG / Release / DesignPreview / 全テストコードの型チェックを実施。`TMPDIR="$PWD/.build/tmp" swift test` は同じモジュールキャッシュのsandbox拒否で停止し、実行0件。GUIでのEsc・入力フォーカス・検索行の余白の確認は未実施。

r2の018統合前には最適化Release実行ファイルを `.build/NotchBrowser-task017-release` に生成し、017の引数・モック固定文章がバイナリに含まれないことを確認した。018統合後のReleaseは型チェックで確認し、モックとプレビュー処理を引き続き `#if DEBUG` 内に限定している。統合後の実行ファイル・GUI・実モデルの実動作確認は未実施。

外部での確認コマンド:

```sh
mkdir -p .build/tmp
TMPDIR="$PWD/.build/tmp" swift test
```
