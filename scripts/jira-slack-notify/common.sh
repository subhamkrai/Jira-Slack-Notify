# shellcheck shell=bash

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
envfile="${JIRA_SLACK_ENV:-$dir/env}"
if [[ -f "$envfile" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$envfile"
  set +a
fi

strip() { printf '%s' "$1" | tr -d ' \r\n\t'; }

JIRA_EMAIL=$(strip "${JIRA_EMAIL:-}")
JIRA_API_TOKEN=$(strip "${JIRA_API_TOKEN:-}")
JIRA_CLOUD_ID=$(strip "${JIRA_CLOUD_ID:-}")

: "${JIRA_EMAIL:?set JIRA_EMAIL}"
: "${JIRA_API_TOKEN:?set JIRA_API_TOKEN}"
: "${JIRA_CLOUD_ID:?set JIRA_CLOUD_ID}"

if [[ ! "$JIRA_CLOUD_ID" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "JIRA_CLOUD_ID looks invalid (expected UUID)" >&2
  exit 1
fi

JIRA_PROJECT="${JIRA_PROJECT:-DFBUGS}"
JIRA_SITE="${JIRA_SITE:-redhat.atlassian.net}"
JIRA_SEARCH_URL="https://api.atlassian.com/ex/jira/${JIRA_CLOUD_ID}/rest/api/3/search/jql"

command -v jq >/dev/null || { echo "need jq" >&2; exit 1; }

jira_curl() {
  local err code out
  err=$(mktemp)
  if ! out=$(curl -sf -m 60 "$@" 2>"$err"); then
    code=$?
    echo "jira request failed (curl exit $code): $(tr '\n' ' ' <"$err")" >&2
    rm -f "$err"
    exit "$code"
  fi
  rm -f "$err"
  printf '%s' "$out"
}

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
    page=$(jira_curl -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
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
  jira_curl -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H 'Accept: application/json' \
    "https://api.atlassian.com/ex/jira/${JIRA_CLOUD_ID}/rest/api/3/issue/$1?fields=summary,components"
}

post_slack() {
  local err code
  err=$(mktemp)
  if ! curl -sf -m 60 -o /dev/null -X POST "$1" -H 'Content-Type: application/json' -d "$2" 2>"$err"; then
    code=$?
    echo "slack post failed (curl exit $code): $(tr '\n' ' ' <"$err")" >&2
    rm -f "$err"
    exit "$code"
  fi
  rm -f "$err"
}
