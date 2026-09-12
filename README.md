# mc-mod-watcher

Minecraft Java版の新バージョン対応状況と、自作ModのCurseForge/Modrinthダウンロード数を監視し、変化があればDiscordに通知します。

## バージョン監視

Minecraft Java版の新バージョン(release/snapshot)と、Fabric/Forge/NeoForgeの対応状況を1時間おきに監視し、変化があればDiscordに通知します。

## 監視対象

- Minecraft本体の最新release/snapshot ([Mojangのバージョンマニフェスト](https://piston-meta.mojang.com/mc/game/version_manifest_v2.json))
- Fabricの対応状況(intermediaryマッピングの公開有無)
- Forgeの対応状況(maven-metadata.xml)
- NeoForgeの対応状況(maven-metadata.xml)

## 仕組み

`scripts/check-versions.sh` が各種メタデータを取得し、`state.json` に保存された前回の値と比較します。変化があった項目のみ、`DISCORD_WEBHOOK_URL` (GitHub Secrets) 宛てにDiscord Webhookで通知します。

`state.json` が存在しない初回実行時は、通知を送らずに現在の状態をそのまま記録します(空リポジトリからの実行でスパム通知にならないようにするため)。

GitHub Actions (`.github/workflows/check-versions.yml`) が1時間おきに実行し、`state.json` の変化を自動でコミットします。手動実行は Actions タブから `workflow_dispatch` で行えます。

## Mod ダウンロード数の監視

`scripts/check-mod-downloads.sh` が CurseForge (`downloadCount`) と Modrinth (`downloads`) の各Modの
ダウンロード数を取得し、`mod-downloads-state.json` に保存された前回値と比較します。増加したModが
あれば、その差分を `DISCORD_WEBHOOK_URL` 宛てに通知します(減少は無視)。

Mod一覧・Modrinthユーザー名は dotfiles `mod-stats.local.sh` と同じ値をスクリプト内に直書きしています。
Mod追加時はスクリプト内の `MODRINTH_EXTRA_IDS` / `CURSEFORGE_MOD_IDS` を更新してください。

`state.json` と同様、初回実行時は通知せず現在の状態を記録するだけです。GitHub Actions
(`.github/workflows/check-mod-downloads.yml`) が1日1回実行します。

## Secrets

- `DISCORD_WEBHOOK_URL`: 通知先のDiscord Webhook URL
- `CURSEFORGE_API_KEY`: CurseForge Core API キー([console.curseforge.com](https://console.curseforge.com/)で無料発行)。未設定の場合はCurseForge側の監視のみスキップされる
