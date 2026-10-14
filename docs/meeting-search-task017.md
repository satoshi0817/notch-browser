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

### universalビルドのfp16修正

Intel macOSではSwiftのFloat16型が利用できないため、本番コードはMeetingFP16でFloatのIEEE 754ビット列をUInt16のbinary16へ変換する。丸めは最近接・偶数丸め。符号付きゼロ、非正規数、通常数の仮数繰り上がり、オーバーフロー、inf / NaNを処理する。BF16の行をFloatに復元して√512倍する順序は維持し、MLMultiArray(.float16)のメモリへUInt16ビット列を書き込む。attention_maskの1は0x3c00、0は0x0000。不正な埋め込み値は従来通り拒否する。

変換テストを5件追加（arm64で5件、IntelではネイティブFloat16との比較テストを除く4件）。arm64専用の参照テスト以外はSwiftのFloat16型を使用しない。別の独立検証プログラムをワークツリー内で実行し、全65536種類のBF16×√512と全31743個の有限fp16区間に対する中点・前後値・正負のネイティブ変換との一致を確認した（不一致0）。

arm64 / x86_64のswift build -c releaseはSwiftPMのマニフェストコンパイル時のサンドボックス拒否で停止した。SDK・ワークツリー内のmodule cacheを明示した両tripleのRelease型チェックは成功し、全テストコードの型チェックも両tripleで成功した。テストメソッド数はarm64で予定402件、Intelではarm64専用の比較を除いて予定401件で、SwiftPMによる全件実行は未実施。Git操作・配布用アプリの変更は行っていない。実Core MLモデルのIntel上での推論は未検証。

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
## 017b: 準備進捗・期限・再試行

`MeetingSearchStore.preparation` は idle → download → compile → ingest → ready、エラー時は failed を公開する。download は取得済みの実バイト＋SHA-256検証済みの再利用ファイルのサイズを、全6ファイル合計 **584,748,275 bytes** で割った整数パーセント。遅れて届くdownload通知でcompileに戻ったり、パーセントが減ったりしない。

- download: 「意味検索を準備中・モデルをダウンロード中 32%」
- compile（tokenizer/語彙読み込みを含む）: 「意味検索を準備中・初回の準備中（数分かかります）」
- ingest: 「意味検索を準備中・12/48件」
- failed: 灰色「意味検索を準備できませんでした」＋「再試行」。再試行はモデルのメモリ状態をリセットし、最初から開始する。ディスク上のモデルファイルはサイズ＋内容SHA-256を再検証し、合格したファイルだけ再利用する。

018の本文取得からsummary+notesを先に取り込むので、準備中・失敗中も文字一致検索を利用できる。文字起こし・画像はインデックスに含めない。macOS 15未満では従来どおり文字一致検索のみ。

`MeetingPreparationTimeouts` の初期値は、stall60秒、compile/モデル読み込み300秒（各試行）、tokenizer/語彙読み込み120秒、各embedding60秒、各Notion本文取得60秒。provider/storeにtimeoutsと`MeetingPreparationClock`を注入できる。ダウンロード全体の期限は削除した。増加した受信バイト通知ごとにstall期限を更新し、最後の増加から60秒間進捗がない場合だけタイムアウトとする。HTTP/通信エラーや検証不一致は通常の失敗。不正なキャッシュファイルは削除し、不足ファイルとともに同じ準備処理で取り直す。

ダウンロードと検証、コンパイル、tokenizer/語彙読み込み、embedding（関数の遅延読み込みを含む）はMainActor外で実行する。コンパイル/初回モデル読み込みは`MeetingCompileCoordinator`が実行中Taskを1つだけ保持し、同時リクエストも同じTaskを待つ。300秒は待機表示へ切り替える期限で、Core MLを停止したとみなす期限ではない。期限切れ時はcompileWaiting「意味検索を準備中・初回の準備の完了を待っています」と表示して文字一致検索を継続し、別のコンパイルやcpuAndGPU読み込みを開始しない。遅れて成功すれば自動でingest → readyに進む。実際に終了して失敗した場合だけ、コンパイル済みURLがあれば再利用して`.cpuAndGPU`で順次再読み込みする。こちらも期限切れ後は同じ実行の完了を待ち、実際の失敗後にfailedとなる。再試行/resetも実行中のコンパイルを破棄しない。embeddingなど他の処理は従来どおり期限切れの結果を破棄する。

失敗時の「再試行」は詳細の「Notion で開く」と同じ青いテキストリンクの見た目（plainスタイル、背景/枠なし）。download/compile/compileWaiting/ingest/failedは同じHStackを使い、`MeetingPreparationLayout.rowHeight = 18pt`と下余白6ptを共有する。失敗状態だけが一覧を押し下げる差をなくした。

Loggerはsubsystem `com.satoshi0817.NotchBrowser`、category `meeting-search`。各段階の開始・終了・失敗、ファイル名と受信バイト数のみを記録する。議事録本文、検索語、認証値、任意のエラー本文は記録しない。

017b追加テスト22件（初版18件から今回4件増、017bの旧タイムアウト期待値も今回仕様へ修正）。追加ケースは同時コンパイル要求の共有、サイズ/SHA-256検証済みファイルのみ再利用、共通行高、遅いコンパイル成功後の自動ready復帰。017bの既存ケースではフェイクclockを2200秒進めながら55秒ごとの進捗で継続すること、stall、期限切れ後の非重複待機、遅い失敗後だけ順次フォールバックを検証する。既存018/017テストは変更しない。フェイクprovider/clockを使用し、実モデルをダウンロードしない。

DEBUG DesignPreview（新しい4状態、既存引数も維持）:

```sh
./scripts/preview.sh --defaults-suite=task017b-download --notion-connection=connected --select-tab=meetings --meeting-search=preparing-download
./scripts/preview.sh --defaults-suite=task017b-compile --notion-connection=connected --select-tab=meetings --meeting-search=preparing-compile
./scripts/preview.sh --defaults-suite=task017b-ingest --notion-connection=connected --select-tab=meetings --meeting-search=preparing-ingest
./scripts/preview.sh --defaults-suite=task017b-failed --notion-connection=connected --select-tab=meetings --meeting-search=preparing-failed
```

プレビューの状態名・固定32%/12/48の値・モック本文は`#if DEBUG`内。Releaseには含めない。実モデルのネットワーク取得、Core MLの実機でのcompile/フォールバック、GUI表示はこの作業では未検証。

検証: DEBUG本体、全テストコード、DesignPreview、およびarm64/x86_64のRelease構成の型チェックは成功。`TMPDIR="$PWD/.build/tmp" swift test` はワークツリー外のモジュールキャッシュ書き込みで停止。キャッシュをワークツリー内に指定した再実行も `sandbox-exec: sandbox_apply: Operation not permitted` でマニフェスト評価が停止し、テスト実行は0件。権限昇格やsandbox設定変更は行っていない。

### Logger全呼び出し監査（017b修正）

SourcesとscriptsのLogger生成/呼び出しを検索。生成1箇所、ログ呼び出し17箇所で、すべてmeeting-search Loggerを使用する。動的な段階名は任意Stringから固定値の`MeetingSearchLogStage` enumへ変更し、本文/題名/検索語を段階名として渡せないようにした。動的値は固定段階名・ピン留めmanifest由来のファイル名・受信バイト数だけで、すべて明示的に`.public`。例外本文、URL、会議ID、本文、題名、検索語、トークンはログに渡さない。

| ファイル / 呼び出し | 記録内容 | 動的値とprivacy |
| --- | --- | --- |
| MeetingSearchPreparation / Logger生成 | subsystem/categoryの固定文字列 | なし |
| MeetingSearchPreparation / timeout開始 | 段階名 + start | 固定enum rawValue: public |
| MeetingSearchPreparation / timeout終了 | 段階名 + end | 固定enum rawValue: public |
| MeetingSearchPreparation / timeout失敗 | 段階名 + failed | 固定enum rawValue: public。例外本文なし |
| MeetingSearchPreparation / compile期限 | compile deadline; waiting for active operation | なし |
| MeetingSearchPreparation / fallback開始 | compile finished with failure; retrying cpuAndGPU | なし |
| MeetingSearchPreparation / 受信進捗 | download、ファイル名、受信バイト数 | manifest由来のファイル名: public、Int64バイト数: public |
| MeetingEmbedding / prepare開始 | preparation start | なし |
| MeetingEmbedding / download終了 | download end | なし |
| MeetingEmbedding / vocabulary開始 | vocabulary start | なし |
| MeetingEmbedding / vocabulary終了・compile開始 | vocabulary end; compile start | なし |
| MeetingEmbedding / compile終了 | compile end | なし |
| MeetingEmbedding / download開始 | download start | なし |
| MeetingEmbedding / embedding開始 | embedding start | なし（埋め込む文章なし） |
| MeetingEmbedding / embedding終了 | embedding end | なし |
| MeetingSearch / ingest開始 | ingest start | なし |
| MeetingSearch / ingest終了 | ingest end | なし |
| MeetingSearch / prepare失敗 | preparation failed | なし（例外本文なし） |

Release監査: `MeetingSearchPreviewState`全体、4つのpreparing-*リテラルを使うstore.preview、Viewのプレビュー分岐は`#if DEBUG`内。新しいcompileWaitingは実運用の状態/文言であり、プレビューのリテラルではない。既存DEBUG起動引数は維持した。

今回の再検証: DEBUG本体、全テストコード、DesignPreview、arm64/x86_64のRelease構成の型チェックは成功。DEBUGを指定しない全ソースのSIL生成も成功し、preparing-download/compile/ingest/failedのstring_literalは0件だった。実モデルとGUIの実機確認は未実施。swift testの実行制限は上記と同じ。

### 017b プランA（表示期限15分）

上記の300秒/compileWaiting表示をプランAで置き換えた。compileの表示期限は900秒（15分）で、順次フォールバックを含む初回準備全体に1つの期限を適用する。期限切れ時は実行中のコンパイル/読み込みを停止せず、既存のfailed行「意味検索を準備できませんでした」＋青い「再試行」リンクを表示する。内部では同じTaskを待ち、文字一致検索を維持する。遅れて成功すれば自動でingestへ進み、取り込み完了後にreadyになる。

この表示上の失敗中に再試行を押すと、表示だけを既存のcompile「意味検索を準備中・初回の準備中（数分かかります）」へ戻す。provider呼び出し、reset、コンパイル、ダウンロード、タイマーの再起動は行わない。実際の準備失敗後の再試行は従来どおり。表示上の失敗を示すフラグはメモリのみで、アプリ再起動後はidleから通常の準備を始める。UIのView・リンクスタイル・18ptの行高は変更していない。

プランAのフェイクclockテストを4件追加（899秒時点/900秒での失敗表示と遅い成功、再試行が表示だけであること、fallbackも元の900秒期限を共有すること、新しいstoreの初期状態）。017bテストは計26件。018/017既存テストは変更していない。この依頼以外の追加実装は行っていない。

プランA検証: DEBUG本体、全テストコード、arm64/x86_64のRelease構成の型チェックは成功。テスト実行は既知のsandbox制限により未確認。UI/実モデルの実機確認は行っていない。
