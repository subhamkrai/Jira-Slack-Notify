#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
source "$dir/common.sh"

: "${SLACK_NOTIFY_WEBHOOK_URL:?set SLACK_NOTIFY_WEBHOOK_URL}"
SLACK_NOTIFY_WEBHOOK_URL=$(strip "${SLACK_NOTIFY_WEBHOOK_URL}")

issue=""
event=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --event) event="$2"; shift 2 ;;
    *) echo "usage: $0 --issue KEY --event opened|moved" >&2; exit 1 ;;
  esac
done

[[ -n "$issue" && ( "$event" == opened || "$event" == moved ) ]] || {
  echo "usage: $0 --issue KEY --event opened|moved" >&2
  exit 1
}

data=$(jira_fetch_issue "$issue")
comps=$(jq -c '[.fields.components[]?.name | select(. == "rook" or . == "odf-cli")]' <<<"$data")
[[ "$comps" != "[]" ]] || exit 0

summary=$(jq -r '.fields.summary // "?"' <<<"$data" | tr '\t' ' ' | sed 's/|/\//g')
comps_label=$(jq -r 'join(", ")' <<<"$comps")
url="https://${JIRA_SITE}/browse/${issue}"

if [[ "$event" == opened ]]; then
  headline="🤦‍♂️ New bug opened to ${comps_label}"
else
  headline="🤦‍♂️ Bug moved to ${comps_label}"
fi

payload=$(jq -nc \
  --arg headline "$headline" \
  --arg url "$url" \
  --arg summary "$summary" \
  '{headline: $headline, url: $url, summary: $summary}')

post_slack "$SLACK_NOTIFY_WEBHOOK_URL" "$payload"
echo "$issue ($event)"
