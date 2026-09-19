#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${STATE_FILE:-state.json}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

MOJANG_MANIFEST_URL="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
FABRIC_INTERMEDIARY_URL="https://meta.fabricmc.net/v2/versions/intermediary"
FORGE_METADATA_URL="https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
NEOFORGE_METADATA_URL="https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"

log() { echo "[check-versions] $*" >&2; }

fetch_mc_versions() {
  curl -fsSL "$MOJANG_MANIFEST_URL"
}

fetch_fabric_versions() {
  curl -fsSL "$FABRIC_INTERMEDIARY_URL"
}

fetch_forge_metadata() {
  curl -fsSL "$FORGE_METADATA_URL"
}

fetch_neoforge_metadata() {
  curl -fsSL "$NEOFORGE_METADATA_URL"
}

# maven-metadata.xml の <version> 一覧は公開順(昇順)なので、
# 指定prefixに一致する最後の要素が該当MCバージョン向けの最新ビルド。
# 該当バージョンがまだ存在しない(grepが0件)のは正常系なので、
# pipefail によってスクリプト全体が落ちないよう `|| true` で吸収する。
latest_version_for_prefix() {
  local xml="$1" prefix="$2"
  echo "$xml" | { grep -oE "<version>${prefix}[^<]*</version>" || true; } | tail -1 | sed -E 's#</?version>##g'
}

# Old scheme: MC release "1.21.9" -> NeoForge version prefix "21.9."
# New scheme (2026-): MC release "26.2" has no "1." prefix, so it passes through unchanged.
neoforge_prefix_for_mc_version() {
  local mc_version="$1"
  echo "${mc_version#1.}."
}

main() {
  log "Fetching Mojang version manifest..."
  local mojang_json mc_release mc_snapshot
  mojang_json="$(fetch_mc_versions)"
  mc_release="$(echo "$mojang_json" | jq -r '.latest.release')"
  mc_snapshot="$(echo "$mojang_json" | jq -r '.latest.snapshot')"

  log "Fetching Fabric intermediary versions..."
  local fabric_json fabric_has_release fabric_has_snapshot
  fabric_json="$(fetch_fabric_versions)"
  fabric_has_release="$(echo "$fabric_json" | jq --arg v "$mc_release" '[.[] | select(.version == $v)] | length > 0')"
  fabric_has_snapshot="$(echo "$fabric_json" | jq --arg v "$mc_snapshot" '[.[] | select(.version == $v)] | length > 0')"

  log "Fetching Forge maven-metadata..."
  local forge_xml forge_latest_version
  forge_xml="$(fetch_forge_metadata)"
  forge_latest_version="$(latest_version_for_prefix "$forge_xml" "${mc_release}-")"

  log "Fetching NeoForge maven-metadata..."
  local neoforge_xml neoforge_prefix neoforge_latest_version
  neoforge_xml="$(fetch_neoforge_metadata)"
  neoforge_prefix="$(neoforge_prefix_for_mc_version "$mc_release")"
  neoforge_latest_version="$(latest_version_for_prefix "$neoforge_xml" "$neoforge_prefix")"

  local new_state
  new_state="$(jq -n \
    --arg mc_release "$mc_release" \
    --arg mc_snapshot "$mc_snapshot" \
    --argjson fabric_has_release "$fabric_has_release" \
    --argjson fabric_has_snapshot "$fabric_has_snapshot" \
    --arg forge_latest_version "$forge_latest_version" \
    --arg neoforge_latest_version "$neoforge_latest_version" \
    '{
      mc_release: $mc_release,
      mc_snapshot: $mc_snapshot,
      fabric_has_release: $fabric_has_release,
      fabric_has_snapshot: $fabric_has_snapshot,
      forge_latest_version: $forge_latest_version,
      neoforge_latest_version: $neoforge_latest_version
    }')"

  local messages=()

  if [[ -f "$STATE_FILE" ]]; then
    local old_state
    old_state="$(cat "$STATE_FILE")"

    local old_mc_release old_mc_snapshot old_fabric_release old_fabric_snapshot old_forge_version old_neoforge_version
    old_mc_release="$(echo "$old_state" | jq -r '.mc_release')"
    old_mc_snapshot="$(echo "$old_state" | jq -r '.mc_snapshot')"
    old_fabric_release="$(echo "$old_state" | jq -r '.fabric_has_release')"
    old_fabric_snapshot="$(echo "$old_state" | jq -r '.fabric_has_snapshot')"
    old_forge_version="$(echo "$old_state" | jq -r '.forge_latest_version // empty')"
    old_neoforge_version="$(echo "$old_state" | jq -r '.neoforge_latest_version // empty')"

    if [[ "$mc_release" != "$old_mc_release" ]]; then
      messages+=("🟢 Minecraft **${mc_release}** (release) がリリースされました")
    fi
    if [[ "$mc_snapshot" != "$old_mc_snapshot" ]]; then
      messages+=("🟡 Minecraft **${mc_snapshot}** (snapshot) が公開されました")
    fi
    if [[ "$fabric_has_release" == "true" && "$old_fabric_release" != "true" ]]; then
      messages+=("🟣 Fabric が **${mc_release}** に対応しました")
    fi
    if [[ "$fabric_has_snapshot" == "true" && "$old_fabric_snapshot" != "true" ]]; then
      messages+=("🟣 Fabric が **${mc_snapshot}** (snapshot) に対応しました")
    fi
    if [[ -n "$forge_latest_version" && "$forge_latest_version" != "$old_forge_version" ]]; then
      messages+=("🔶 Forge **${mc_release}** 用ビルド ${forge_latest_version} が公開されました")
    fi
    if [[ -n "$neoforge_latest_version" && "$neoforge_latest_version" != "$old_neoforge_version" ]]; then
      messages+=("🔷 NeoForge **${mc_release}** 用ビルド ${neoforge_latest_version} が公開されました")
    fi
  else
    log "No existing state file found. Seeding initial state without notification."
  fi

  echo "$new_state" > "$STATE_FILE"

  if [[ "${#messages[@]}" -eq 0 ]]; then
    log "No changes detected."
    exit 0
  fi

  log "Changes detected:"
  printf '%s\n' "${messages[@]}" >&2

  if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
    log "DISCORD_WEBHOOK_URL is not set. Skipping notification."
    exit 0
  fi

  local content
  content="$(printf '%s\n' "${messages[@]}")"

  local payload
  payload="$(jq -n --arg content "$content" '{content: $content}')"

  curl -fsSL -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" > /dev/null
  log "Notification sent."
}

main "$@"
