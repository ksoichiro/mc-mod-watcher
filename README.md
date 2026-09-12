# mc-version-watcher

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

## Secrets

- `DISCORD_WEBHOOK_URL`: 通知先のDiscord Webhook URL
