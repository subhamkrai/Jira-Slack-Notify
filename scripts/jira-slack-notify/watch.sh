#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
source "$dir/common.sh"

state="${JIRA_SLACK_STATE_FILE:-$dir/.watch-state.json}"
init=0
[[ "${1:-}" == --init ]] && init=1

jql="project = ${JIRA_PROJECT} AND issuetype = Bug AND (component in (rook, odf-cli) OR updated >= -30m) ORDER BY updated DESC"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

jira_search "$jql" >"$tmp"

snapshot() {
  jq '[.[] | {key: .key, comps: [.fields.components[]?.name | select(. == "rook" or . == "odf-cli")]}]
    | map({(.key): .comps}) | add // {}' "$tmp"
}

if [[ ! -f "$state" || "$init" -eq 1 ]]; then
  snapshot >"$state"
  echo "seeded $(jq 'length' "$state") issues"
  exit 0
fi

jq -s '.[0] + .[1]' "$state" <(snapshot) >"${state}.tmp"

jq -s --slurpfile issues "$tmp" '
  (.[0]) as $prev |
  [$issues[0][] |
    .key as $key |
    [.fields.components[]?.name | select(. == "rook" or . == "odf-cli")] as $now |
    ($prev[$key] // []) as $was |
    if ($now | length) == 0 then empty
    elif ($was | length) == 0 then
      if (((.fields.created // "") | split("T")[0] | strptime("%Y-%m-%d") | mktime) > (now - 86400)) then
        {key: $key, event: "opened"}
      else
        {key: $key, event: "moved"}
      end
    elif ($now - $was | length) > 0 then {key: $key, event: "moved"}
    else empty
    end
  ]
' "$state" >"${tmp}.events"

notified=0
while IFS= read -r row; do
  key=$(jq -r '.key' <<<"$row")
  ev=$(jq -r '.event' <<<"$row")
  if "$dir/notify.sh" --issue "$key" --event "$ev"; then
    notified=$((notified + 1))
  fi
done < <(jq -c '.[]' "${tmp}.events")

mv "${state}.tmp" "$state"
echo "events=$(jq 'length' "${tmp}.events") notified=$notified"
