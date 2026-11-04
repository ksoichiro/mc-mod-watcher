#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${STATE_FILE:-mod-downloads-state.json}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
CURSEFORGE_API_KEY="${CURSEFORGE_API_KEY:-}"

MODRINTH_API="https://api.modrinth.com/v2"
CURSEFORGE_API="https://api.curseforge.com/v1"

MODRINTH_USER="ksoichiro"
# Projects that do not appear in the user's project list (treated as organization-owned).
MODRINTH_EXTRA_IDS=("yggUWseW")
# On CurseForge, search by author ID to pick up my mods automatically,
# so newly added mods are not missed.
CURSEFORGE_AUTHOR_ID="103748140"
# As a fallback for mods missing from the author search, also fetch known mods individually.
CURSEFORGE_MOD_IDS=(1414198 1449883 1485856 1459678 1457302 1474573 1462226 677895 1452132 1459633 1456423 1702768)

log() { echo "[check-mod-downloads] $*" >&2; }

# --retry-all-errors: upstream APIs sometimes return transient 404/5xx,
# so retry on HTTP errors as well.
CURL_RETRY_OPTS=(--retry 3 --retry-delay 2 --retry-all-errors)

# Split notification lines into multiple chunks so each stays under Discord's
# per-message limit (2000 characters). 1900 leaves a safety margin.
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
  # flags: 4 = SUPPRESS_EMBEDS. Keeps link-heavy messages from expanding
  # into a long run of preview embeds.
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

# CurseForge mod objects are huge (screenshots, file lists), and passing search
# results directly via --argjson exceeds the argument length limit (128KB per
# argument on Linux). Pipe the response to jq via stdin and keep only the
# fields we need.
CURSEFORGE_SLIM_MOD='{id, name, downloads: .downloadCount, url: .links.websiteUrl}'

fetch_curseforge_downloads() {
  local mods="[]"
  local index=0 page_size=50 page total
  while :; do
    page="$(curl -fsSL "${CURL_RETRY_OPTS[@]}" -H "x-api-key: $CURSEFORGE_API_KEY" \
      "$CURSEFORGE_API/mods/search?gameId=432&authorId=${CURSEFORGE_AUTHOR_ID}&pageSize=${page_size}&index=${index}" |
      jq "{total: .pagination.totalCount, mods: [.data[] | $CURSEFORGE_SLIM_MOD]}")"
    mods="$(jq -n --argjson a "$mods" --argjson p "$page" '$a + $p.mods')"
    total="$(echo "$page" | jq '.total')"
    index=$((index + page_size))
    [[ "$index" -lt "$total" ]] || break
  done

  local mod_id data
  for mod_id in "${CURSEFORGE_MOD_IDS[@]}"; do
    if ! echo "$mods" | jq -e --argjson id "$mod_id" 'any(.[]; .id == $id)' > /dev/null; then
      data="$(curl -fsSL "${CURL_RETRY_OPTS[@]}" -H "x-api-key: $CURSEFORGE_API_KEY" "$CURSEFORGE_API/mods/${mod_id}" |
        jq ".data | $CURSEFORGE_SLIM_MOD")"
      mods="$(jq -n --argjson a "$mods" --argjson d "$data" '$a + [$d]')"
    fi
  done

  echo "$mods" | jq 'map({(.name): {downloads, url}}) | add // {}'
}

# Build notification lines only for mods whose count increased. Decreases
# (e.g. a withdrawn file) are ignored.
# Mods missing from the previous state are reported as newly detected. If the
# previous state for that source was empty (first run, or a run that skipped it
# for lack of an API key), every mod would look new, so nothing is reported.
# Values in $old may use the old schema (a number) or the new one (an object
# with downloads/url).
diff_downloads() {
  local source_label="$1" old_json="$2" new_json="$3"
  jq -n --argjson old "$old_json" --argjson new "$new_json" --arg label "$source_label" -r '
    $new | to_entries[] |
    ($old[.key] // null) as $old_raw |
    (if ($old_raw | type) == "object" then $old_raw.downloads else $old_raw end) as $old_count |
    if $old_count == null then
      select($old | length > 0) |
      "🆕 \($label) [\(.key)](\(.value.url)): newly detected (\(.value.downloads) downloads total)"
    else
      select(.value.downloads > $old_count) |
      "📈 \($label) [\(.key)](\(.value.url)): +\(.value.downloads - $old_count) downloads (\(.value.downloads) total)"
    end
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
