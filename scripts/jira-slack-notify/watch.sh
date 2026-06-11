#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
source "$dir/common.sh"

state="${JIRA_SLACK_STATE_FILE:-$dir/.watch-state.json}"
init=0
[[ "${1:-}" == --init ]] && init=1

# Only bugs with rook/odf-cli today; no broad "updated" clause (avoids stale re-notify noise).
jql="project = ${JIRA_PROJECT} AND issuetype = Bug AND component in (rook, odf-cli) ORDER BY updated DESC"

tmp=$(mktemp)
events="${tmp}.events"
state_tmp="${state}.tmp"
trap 'rm -f "$tmp" "$events" "$state_tmp"' EXIT

jira_search "$jql" >"$tmp"

snapshot() {
  jq '[.[] |
      {key: .key, comps: [.fields.components[]?.name | select(. == "rook" or . == "odf-cli")]}
      | select(.comps | length > 0)]
    | map({(.key): .comps}) | add // {}' "$tmp"
}

if [[ ! -f "$state" || "$init" -eq 1 ]]; then
  snapshot >"$state"
  echo "seeded $(jq 'length' "$state") issues"
  exit 0
fi

if ! jq -e 'type == "object"' "$state" >/dev/null; then
  echo "invalid state, re-seeding" >&2
  snapshot >"$state"
  echo "seeded $(jq 'length' "$state") issues"
  exit 0
fi

# Empty {} cache — re-seed silently (prevents mass false notifications).
if [[ "$(jq 'length' "$state")" -eq 0 ]]; then
  echo "empty state, re-seeding" >&2
  snapshot >"$state"
  echo "seeded $(jq 'length' "$state") issues"
  exit 0
fi

jq -s '.[0] + .[1]' "$state" <(snapshot) >"$state_tmp"

jq -s --slurpfile issues "$tmp" '
  (.[0]) as $prev |
  def recent_created:
    (.fields.created // "") as $c |
    ($c | length) > 9 and
    (($c | split("T")[0] | strptime("%Y-%m-%d") | mktime) > (now - 86400));
  [$issues[0][] |
    .key as $key |
    [.fields.components[]?.name | select(. == "rook" or . == "odf-cli")] as $now |
    ($prev | has($key)) as $seen |
    ($prev[$key] // []) as $was |
    if ($now | length) == 0 then empty
    elif ($seen | not) then
      if recent_created then {key: $key, event: "opened"}
      else {key: $key, event: "moved"}
      end
    elif ($was | length) == 0 then {key: $key, event: "moved"}
    elif ($now - $was | length) > 0 then {key: $key, event: "moved"}
    else empty
    end
  ]
' "$state" >"$events"

# Persist state before Slack so a partial notify run still advances state.
mv "$state_tmp" "$state"

notified=0
while IFS= read -r row; do
  key=$(jq -r '.key' <<<"$row")
  ev=$(jq -r '.event' <<<"$row")
  if "$dir/notify.sh" --issue "$key" --event "$ev"; then
    notified=$((notified + 1))
  else
    echo "notify failed: $key ($ev)" >&2
  fi
done < <(jq -c '.[]' "$events")

echo "events=$(jq 'length' "$events") notified=$notified tracked=$(jq 'length' "$state")"
