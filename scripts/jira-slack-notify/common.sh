# shellcheck shell=bash

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
envfile="${JIRA_SLACK_ENV:-$dir/env}"
if [[ -f "$envfile" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$envfile"
  set +a
fi

: "${JIRA_EMAIL:?}"
: "${JIRA_API_TOKEN:?}"
: "${JIRA_CLOUD_ID:?}"

JIRA_PROJECT="${JIRA_PROJECT:-DFBUGS}"
JIRA_SITE="${JIRA_SITE:-redhat.atlassian.net}"
JIRA_SEARCH_URL="https://api.atlassian.com/ex/jira/${JIRA_CLOUD_ID}/rest/api/3/search/jql"

command -v jq >/dev/null || { echo "need jq" >&2; exit 1; }

jira_search() {
  local jql="$1" token="" page body merged result
  result=$(mktemp)
  echo '[]' >"$result"
  while :; do
    if [[ -n "$token" ]]; then
      body=$(jq -nc --arg jql "$jql" --arg token "$token" \
        '{jql: $jql, maxResults: 100, fields: ["summary","components","created"], nextPageToken: $token}')
    else
      body=$(jq -nc --arg jql "$jql" \
        '{jql: $jql, maxResults: 100, fields: ["summary","components","created"]}')
    fi
    page=$(curl -sf -m 60 -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      -X POST "$JIRA_SEARCH_URL" -d "$body")
    if err=$(jq -r '.errorMessages[0] // empty' <<<"$page"); [[ -n "$err" ]]; then
      echo "jira: $err" >&2
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
  curl -sf -m 60 -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H 'Accept: application/json' \
    "https://api.atlassian.com/ex/jira/${JIRA_CLOUD_ID}/rest/api/3/issue/$1?fields=summary,components"
}

post_slack() {
  curl -sf -m 60 -X POST "$1" -H 'Content-Type: application/json' -d "$2"
}
