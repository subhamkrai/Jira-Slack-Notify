# Shared Jira → Slack helpers (source from other scripts; do not execute directly).
[[ -n "${JIRA_SLACK_NOTIFY_COMMON_LOADED:-}" ]] && return 0
JIRA_SLACK_NOTIFY_COMMON_LOADED=1

NOTIFY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${JIRA_SLACK_ENV:-$NOTIFY_ROOT/env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

: "${JIRA_EMAIL:?Set JIRA_EMAIL in $ENV_FILE or GitHub Actions secrets}"
: "${JIRA_API_TOKEN:?Set JIRA_API_TOKEN in $ENV_FILE or GitHub Actions secrets}"

": "${JIRA_CLOUD_ID:?Set JIRA_CLOUD_ID in $ENV_FILE or GitHub Actions secrets}"
JIRA_PROJECT="${JIRA_PROJECT:-DFBUGS}"
JIRA_SITE="${JIRA_SITE:-redhat.atlassian.net}"
JIRA_SEARCH_URL="https://api.atlassian.com/ex/jira/${JIRA_CLOUD_ID}/rest/api/3/search/jql"
ISSUE_FIELDS='["summary","assignee","components","created","updated","issuetype","status"]'

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

jira_search() {
  local jql="$1" token="" page body merged result
  result=$(mktemp)
  echo '[]' >"$result"
  while :; do
    if [[ -n "$token" ]]; then
      body=$(jq -nc --arg jql "$jql" --arg token "$token" \
        "{jql:\$jql, maxResults:100, fields:${ISSUE_FIELDS}, nextPageToken:\$token}")
    else
      body=$(jq -nc --arg jql "$jql" \
        "{jql:\$jql, maxResults:100, fields:${ISSUE_FIELDS}}")
    fi
    page=$(curl -sf -m 60 -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      -X POST "$JIRA_SEARCH_URL" -d "$body")
    if err=$(jq -r '.errorMessages[0] // empty' <<<"$page"); [[ -n "$err" ]]; then
      echo "Jira error: $err" >&2
      echo "JQL: $jql" >&2
      rm -f "$result"
      exit 1
    fi
    merged=$(mktemp)
    jq -s 'add' "$result" <(jq -c '.issues // []' <<<"$page") >"$merged"
    mv "$merged" "$result"
    token=$(jq -r '.nextPageToken // empty' <<<"$page")
    [[ -z "$token" ]] && break
  done
  cat "$result"
  rm -f "$result"
}

jira_fetch_issue() {
  local key="$1"
  curl -sf -m 60 -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H 'Accept: application/json' \
    "https://api.atlassian.com/ex/jira/${JIRA_CLOUD_ID}/rest/api/3/issue/${key}?fields=summary,assignee,components,created,updated,issuetype,status"
}

issue_target_components() {
  jq -c '[.fields.components[]?.name | select(. == "rook" or . == "odf-cli")]'
}

issue_jira_url() {
  local key="$1"
  printf 'https://%s/browse/%s' "$JIRA_SITE" "$key"
}

post_slack() {
  local webhook="${1:?webhook required}" payload="$2"
  curl -sf -m 60 -X POST "$webhook" \
    -H 'Content-Type: application/json' \
    -d "$payload"
}
