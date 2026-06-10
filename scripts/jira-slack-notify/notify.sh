#!/usr/bin/env bash
# Post a single Slack notification when a DFBUGS bug is opened or moved to rook/odf-cli.
#
#   ./scripts/jira-slack-notify/notify.sh --issue DFBUGS-123 --event opened
#   ./scripts/jira-slack-notify/notify.sh --issue DFBUGS-123 --event moved

set -euo pipefail

NOTIFY_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/jira-slack-notify/common.sh
source "$NOTIFY_DIR/common.sh"

: "${SLACK_NOTIFY_WEBHOOK_URL:?Set SLACK_NOTIFY_WEBHOOK_URL in env or GitHub Actions secrets}"

if [[ "$SLACK_NOTIFY_WEBHOOK_URL" == *"slack.com/shortcuts"* ]]; then
  echo "Use the Workflow webhook URL (hooks.slack.com/triggers/...), not a shortcut link." >&2
  exit 1
fi

issue_key=""
event=""

usage() {
  echo "Usage: $0 --issue KEY --event opened|moved" >&2
  echo "       $0   # read JSON from stdin: {key, event} or full Jira issue" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) issue_key="$2"; shift 2 ;;
    --event) event="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

issue_json=""
if [[ -z "$issue_key" && ! -t 0 ]]; then
  input=$(cat)
  issue_key=$(jq -r '.key // .issue.key // empty' <<<"$input")
  event=$(jq -r '.event // empty' <<<"$input")
  if jq -e '.fields' >/dev/null 2>&1 <<<"$input"; then
    issue_json="$input"
  elif jq -e '.issue.fields' >/dev/null 2>&1 <<<"$input"; then
    issue_json=$(jq '.issue' <<<"$input")
  fi
fi

[[ -n "$issue_key" ]] || usage
[[ "$event" == "opened" || "$event" == "moved" ]] || {
  echo "event must be opened or moved" >&2
  exit 1
}

if [[ -z "$issue_json" ]]; then
  issue_json=$(jira_fetch_issue "$issue_key")
fi

comps=$(issue_target_components <<<"$issue_json")
if [[ "$comps" == "[]" ]]; then
  echo "Issue $issue_key has no rook/odf-cli component; skipping." >&2
  exit 0
fi

summary=$(jq -r '.fields.summary // "?"' <<<"$issue_json" \
  | tr '\t' ' ' | sed 's/|/\//g')
assignee=$(jq -r '.fields.assignee.displayName // "Unassigned"' <<<"$issue_json")
status=$(jq -r '.fields.status.name // "?"' <<<"$issue_json")
comp_label=$(jq -r 'join(", ")' <<<"$comps")
url=$(issue_jira_url "$issue_key")

if [[ "$event" == "opened" ]]; then
  headline="🆕 New bug opened: ${issue_key}"
else
  headline="📥 Bug moved to rook/odf-cli: ${issue_key}"
fi

if [[ "$SLACK_NOTIFY_WEBHOOK_URL" == *"/services/"* ]]; then
  message="${headline}
Component: ${comp_label}
Status: ${status}
Assignee: ${assignee}
Summary: ${summary}
${url}"
  payload=$(jq -nc --arg text "$message" '{text: $text}')
else
  payload=$(jq -nc \
    --arg headline "$headline" \
    --arg issue_key "$issue_key" \
    --arg event "$event" \
    --arg component "$comp_label" \
    --arg status "$status" \
    --arg assignee "$assignee" \
    --arg summary "$summary" \
    --arg url "$url" \
    '{
      headline: $headline,
      issue_key: $issue_key,
      event: $event,
      component: $component,
      status: $status,
      assignee: $assignee,
      summary: $summary,
      url: $url
    }')
fi

post_slack "$SLACK_NOTIFY_WEBHOOK_URL" "$payload"
echo "Notified Slack: ${issue_key} (${event})."
