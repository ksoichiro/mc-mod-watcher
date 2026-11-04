# mc-mod-watcher

Watches Minecraft Java Edition version support and the CurseForge/Modrinth download counts of my own mods, and notifies Discord when something changes.

## Version watcher

Checks hourly for new Minecraft Java Edition versions (release/snapshot) and for Fabric/Forge/NeoForge support, and notifies Discord on any change.

### What is watched

- Latest Minecraft release/snapshot ([Mojang version manifest](https://piston-meta.mojang.com/mc/game/version_manifest_v2.json))
- Fabric support (whether intermediary mappings are published)
- Forge support (maven-metadata.xml)
- NeoForge support (maven-metadata.xml)

### How it works

`scripts/check-versions.sh` fetches the metadata and compares it with the previous values stored in `state.json`. Only items that changed are sent via Discord webhook to `DISCORD_WEBHOOK_URL` (GitHub Secrets).

On the first run, when `state.json` does not exist, the current state is recorded without sending any notification (to avoid a flood of notifications from an empty repository).

GitHub Actions (`.github/workflows/check-versions.yml`) runs hourly and commits changes to `state.json` automatically. You can also run it manually from the Actions tab via `workflow_dispatch`.

## Mod download watcher

`scripts/check-mod-downloads.sh` fetches the download count of each mod from CurseForge (`downloadCount`) and Modrinth (`downloads`) and compares it with the previous values stored in `mod-downloads-state.json`. If any mod's count increased, the difference is sent to `DISCORD_WEBHOOK_URL` (decreases are ignored). A mod that is not in the previous state is reported as newly detected.

Mods are discovered automatically from the Modrinth username (`MODRINTH_USER`) and the CurseForge author ID (`CURSEFORGE_AUTHOR_ID`), so the script does not need updating when a mod is added. Only mods that do not appear in the user/author listing need to be added to `MODRINTH_EXTRA_IDS` / `CURSEFORGE_MOD_IDS`.

As with `state.json`, the first run only records the current state without notifying. GitHub Actions (`.github/workflows/check-mod-downloads.yml`) runs it once a day.

## Secrets

- `DISCORD_WEBHOOK_URL_VERSIONS`: Discord webhook URL for version watcher notifications
- `DISCORD_WEBHOOK_URL_DOWNLOADS`: Discord webhook URL for download watcher notifications
- `CURSEFORGE_API_KEY`: CurseForge Core API key (free from [console.curseforge.com](https://console.curseforge.com/)). If unset, only the CurseForge side of the download watcher is skipped

## License

[MIT](LICENSE)
