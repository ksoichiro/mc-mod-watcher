#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${STATE_FILE:-mod-downloads-state.json}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
CURSEFORGE_API_KEY="${CURSEFORGE_API_KEY:-}"

MODRINTH_API="https://api.modrinth.com/v2"
CURSEFORGE_API="https://api.curseforge.com/v1"

MODRINTH_USER="ksoichiro"
# ユーザーのプロジェクト一覧に出ない(組織所有扱いの)プロジェクト。
MODRINTH_EXTRA_IDS=("yggUWseW")
# dotfiles mod-stats.local.sh と同じ11本(2026-08-24確定)。
CURSEFORGE_MOD_IDS=(1414198 1449883 1485856 1459678 1457302 1474573 1462226 677895 1452132 1459633 1456423)

log() { echo "[check-mod-downloads] $*" >&2; }

# --retry-all-errors: 上流APIが一時的に404/5xxを返すことがあるため、
# HTTPエラーもリトライ対象に含める。
CURL_RETRY_OPTS=(--retry 3 --retry-delay 2 --retry-all-errors)

# Discordの1メッセージあたりの上限(2000文字)を超えないよう、
# 通知行を複数チャンクに分けて送信する。1900文字を安全マージンとする。
DISCORD_CONTENT_LIMIT=1900

send_discord_notification() {
  local webhook_url="$1"
  shift
  local -a lines=("$@")
  local -a chunk=()
  local chunk_len=0

  local line line_len

  for line in "${lines[@]}"; do
    line_len=${#line}
    if [[ "$chunk_len" -gt 0 && $((chunk_len + line_len + 1)) -gt "$DISCORD_CONTENT_LIMIT" ]]; then
      post_discord_chunk "$webhook_url" "${chunk[@]}"
      chunk=()
      chunk_len=0
    fi
    chunk+=("$line")
    chunk_len=$((chunk_len + line_len + 1))
  done

  if [[ "${#chunk[@]}" -gt 0 ]]; then
    post_discord_chunk "$webhook_url" "${chunk[@]}"
  fi
}

post_discord_chunk() {
  local webhook_url="$1"
  shift
  local content payload
  content="$(printf '%s\n' "$@")"
  # flags: 4 = SUPPRESS_EMBEDS。リンクだらけのメッセージでプレビュー画像が
  # ずらずら展開されるのを防ぐ。
  payload="$(jq -n --arg content "$content" '{content: $content, flags: 4}')"
  curl -fsSL "${CURL_RETRY_OPTS[@]}" -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_url" > /dev/null
}

fetch_modrinth_downloads() {
  local projects
  projects="$(curl -fsSL "${CURL_RETRY_OPTS[@]}" "$MODRINTH_API/user/${MODRINTH_USER}/projects")"

  local id
  for id in "${MODRINTH_EXTRA_IDS[@]}"; do
    if ! echo "$projects" | jq -e --arg id "$id" 'any(.[]; .id == $id)' > /dev/null; then
      local extra
      extra="$(curl -fsSL "${CURL_RETRY_OPTS[@]}" "$MODRINTH_API/project/${id}")"
      projects="$(jq -n --argjson a "$projects" --argjson b "$extra" '$a + [$b]')"
    fi
  done

  echo "$projects" | jq 'map({(.title): {downloads: .downloads, url: ("https://modrinth.com/" + .project_type + "/" + .slug)}}) | add // {}'
}

fetch_curseforge_downloads() {
  local result="{}"
  local mod_id data
  for mod_id in "${CURSEFORGE_MOD_IDS[@]}"; do
    data="$(curl -fsSL "${CURL_RETRY_OPTS[@]}" -H "x-api-key: $CURSEFORGE_API_KEY" "$CURSEFORGE_API/mods/${mod_id}")"
    result="$(jq -n --argjson acc "$result" --argjson d "$data" '$acc + {($d.data.name): {downloads: $d.data.downloadCount, url: $d.data.links.websiteUrl}}')"
  done
  echo "$result"
}

# 前回値より増えたModだけ通知行を作る。減少(取り下げ等)は無視する。
# $old の値は旧スキーマ(数値)/新スキーマ(downloads/urlを持つオブジェクト)のどちらもあり得る。
diff_downloads() {
  local source_label="$1" old_json="$2" new_json="$3"
  jq -n --argjson old "$old_json" --argjson new "$new_json" --arg label "$source_label" -r '
    $new | to_entries[] |
    ($old[.key] // null) as $old_raw |
    (if ($old_raw | type) == "object" then $old_raw.downloads else $old_raw end) as $old_count |
    select($old_count != null and .value.downloads > $old_count) |
    "📈 \($label) [\(.key)](\(.value.url)): +\(.value.downloads - $old_count) DL (累計 \(.value.downloads))"
  '
}

main() {
  local new_cf="{}"
  if [[ -n "$CURSEFORGE_API_KEY" ]]; then
    log "Fetching CurseForge download counts..."
    new_cf="$(fetch_curseforge_downloads)"
  else
    log "CURSEFORGE_API_KEY is not set. Skipping CurseForge."
  fi

  log "Fetching Modrinth download counts..."
  local new_mr
  new_mr="$(fetch_modrinth_downloads)"

  local new_state
  new_state="$(jq -n --argjson cf "$new_cf" --argjson mr "$new_mr" '{curseforge: $cf, modrinth: $mr}')"

  local messages=()

  if [[ -f "$STATE_FILE" ]]; then
    local old_state old_cf old_mr
    old_state="$(cat "$STATE_FILE")"
    old_cf="$(echo "$old_state" | jq '.curseforge // {}')"
    old_mr="$(echo "$old_state" | jq '.modrinth // {}')"

    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && messages+=("$line")
    done < <(diff_downloads "CurseForge" "$old_cf" "$new_cf")

    while IFS= read -r line; do
      [[ -n "$line" ]] && messages+=("$line")
    done < <(diff_downloads "Modrinth" "$old_mr" "$new_mr")
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

  send_discord_notification "$DISCORD_WEBHOOK_URL" "${messages[@]}"
  log "Notification sent."
}

main "$@"
