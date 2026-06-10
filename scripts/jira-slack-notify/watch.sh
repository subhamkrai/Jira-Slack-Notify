#!/usr/bin/env bash
# Poll Jira and post Slack notifications for bugs opened or moved to rook/odf-cli.
#
# Local:
#   cp scripts/jira-slack-notify/env.example scripts/jira-slack-notify/env
#   ./scripts/jira-slack-notify/watch.sh --init   # first run: seed state, no Slack
#   ./scripts/jira-slack-notify/watch.sh
#
# GitHub Actions: see .github/workflows/jira-slack-watch.yaml

set -euo pipefail

NOTIFY_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/jira-slack-notify/common.sh
source "$NOTIFY_DIR/common.sh"

STATE_FILE="${JIRA_SLACK_STATE_FILE:-$NOTIFY_DIR/.watch-state.json}"
INIT_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init) INIT_ONLY=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--init]" >&2
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

WATCH_JQL="project = ${JIRA_PROJECT} AND issuetype = Bug AND (component in (rook, odf-cli) OR updated >= -30m) ORDER BY updated DESC"

issues_file=$(mktemp)
events_file=$(mktemp)
new_state_file=$(mktemp)
trap 'rm -f "$issues_file" "$events_file" "$new_state_file"' EXIT

jira_search "$WATCH_JQL" >"$issues_file"

build_state_delta() {
  jq '[.[] | {key: .key, comps: [.fields.components[]?.name | select(. == "rook" or . == "odf-cli")]}]
    | map({(.key): .comps}) | add // {}' "$issues_file"
}

if [[ ! -f "$STATE_FILE" || "$INIT_ONLY" -eq 1 ]]; then
  build_state_delta >"$STATE_FILE"
  echo "Initialized state at $STATE_FILE ($(jq 'length' "$STATE_FILE") issues, no notifications)."
  exit 0
fi

jq -s '
  (.[0]) as $prev |
  (.[1]) as $delta |
  $prev + $delta
' "$STATE_FILE" <(build_state_delta) >"$new_state_file"

jq -s --slurpfile issues "$issues_file" '
  (.[0]) as $prev |
  ($issues[0]) as $all |
  def target_comps:
    [.fields.components[]?.name | select(. == "rook" or . == "odf-cli")];
  def recent_created:
    ((.fields.created // "") | split("T")[0]) as $d |
    ($d | strptime("%Y-%m-%d") | mktime) > (now - 86400);
  [$all[] |
    . as $issue |
    target_comps as $now |
    ($prev[$issue.key] // null) as $was |
    if ($now | length) == 0 then empty
    elif $was == null or ($was | length) == 0 then
      if recent_created then {key: $issue.key, event: "opened"}
      else {key: $issue.key, event: "moved"}
      end
    elif ($now - $was | length) > 0 then {key: $issue.key, event: "moved"}
    else empty
    end
  ]
' "$STATE_FILE" >"$events_file"

count=$(jq 'length' "$events_file")
notified=0

if [[ "$count" -gt 0 ]]; then
  while IFS= read -r row; do
    key=$(jq -r '.key' <<<"$row")
    event=$(jq -r '.event' <<<"$row")
    if "$NOTIFY_DIR/notify.sh" --issue "$key" --event "$event"; then
      notified=$((notified + 1))
    else
      echo "Failed to notify $key ($event)." >&2
    fi
  done < <(jq -c '.[]' "$events_file")
fi

cp "$new_state_file" "$STATE_FILE"
echo "Watch complete (events=${count}, notified=${notified}, tracked=$(jq 'length' "$STATE_FILE"))."
