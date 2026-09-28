# 2026-09-29 調査と採用判断

公式仕様と利用者の要望を区別して確認。機能単位の利用率や人気ランキングは取得していないため、「人気が確定した機能」とは扱わない。

| 出典 | 確認した点 | 今回の判断 |
|---|---|---|
| [MenubarX公式](https://menubarx.app/) | 小型ブラウザ、固定、サイズ変更、自動更新 | 既存の固定・サイズ設定を維持し、30秒／1分／5分の自動更新を追加。明示的に有効にしたタブだけ更新する |
| [同名の別製品 NotchBrowser / Block Browser](https://apps.apple.com/us/app/notchbrowser/id6760988979?mt=12) | ページ内検索、ズーム、閉じたタブ復元、タブ永続化など | 検索・ズーム・セッション内の閉じたタブ復元を採用。これはこのリポジトリの製品ではない |
| [Reddit: Suggestions for Notch apps](https://www.reddit.com/r/macapps/comments/1utcikk/suggestions_for_notch_apps/) | ノートへの素早いアクセスの要望。短時間で使える情報を求める意見 | ページを見ながら使える小さなメモ欄。メモはプロファイル別でローカル保存 |
| [Reddit: Synapseへの機能要望](https://www.reddit.com/r/macapps/comments/1svaxi1/i_built_a_1mb_mac_app_that_replaces_7_tools_notch/) | scratchpadの提案、キーボード操作、機能を増やしすぎない／不要なUIを隠す要望 | クイックメモとURL添付、タブ検索の上下キー操作。新機能は操作メニューにまとめる |
| [Reddit: タブとアプリの切り替え要望](https://www.reddit.com/r/macapps/comments/1u76esz/request_an_app_to_switch_between/) | ブラウザタブに直接移動できるキーボード操作 | このアプリ内のタブ名・URL・プロファイル検索を追加。外部アプリの操作は行わない |
| [MenubarXの利用者レビュー](https://apps.apple.com/us/app/menubarx-floating-browser/id1575588022?mt=12&platform=mac&see-all=reviews) | 自分で並べられるホーム画面の要望、長時間利用時のメモリ懸念 | 新規タブから既存の固定ページへ移動可能に。常時監視やメディア解析を増やさない |
| [Apple iOS 27](https://www.apple.com/os/ios/) | Liquid Glassの読みやすさ、コントラスト、濃度調整 | ユーザー指定に合わせ、ノッチの従来の輪郭・1段配置を維持。背景・枠のみガラス素材と濃度調整 |
| [Apple SF Symbols](https://developer.apple.com/sf-symbols/) | Appleプラットフォーム向けの統一シンボルライブラリ | すべてのアプリ内アイコンをSF Symbolsで統一。絵文字・画像・faviconの描画を停止し、保存済み設定は壊さず自動シンボル表示 |

## Xの確認範囲

NotchNook / MenubarX / notch quick notesなどの公開投稿を検索。https://x.com/MenubarX は403、X検索ページも取得できなかった。Xの投稿本文を確認できたとは扱わず、Xを採用根拠にした機能や人気の断定はない。

## 実装範囲

- ページ内検索、前後の一致、0.5〜3倍のページズーム。
- 閉じた通常タブを最大20件、URL・プロファイル・ズーム付きで復元。履歴はセッション内のみ。
- タブ検索、上下キー・Return・Escapeで操作。
- 明示的な自動更新。タブを閉じるかプロファイルを変更すると停止。
- クイックメモはプロファイル別にローカル自動保存、現在ページのタイトル・URLを追記可能。
- macOS 26以降はNSGlassEffectView、macOS 14/15はNSVisualEffectView。透明度低減・高コントラスト設定を尊重。
- キーボードフォーカスを奪わないホバー表示、青い選択状態、閉じるまでの待ち時間、カメラ位置の空白を維持。

## 検証の限界

動作と画面の実機確認はmacOS 15。macOS 26以降の純正Liquid Glass経路はSDKでコンパイルを確認したが、対応OS上の描画を実機確認していない。
