#!/bin/sh
set -eu

log() {
  level="$1"
  shift
  message="$*"
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$message"
}

ensure_binary() {
  bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    log ERROR "Required binary $bin not found in PATH"
    exit 1
  fi
}

require_env() {
  var="$1"
  desc="$2"
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    log ERROR "Environment variable $var ($desc) must be set when ALERT_MODE=${ALERT_MODE:-unknown}"
    exit 1
  fi
}

trim_whitespace() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

json_escape() {
  printf '%s' "$1" | awk '{
    gsub(/\\/, "\\\\")
    gsub(/"/, "\\\"")
    if (NR == 1) {
      printf "%s", $0
    } else {
      printf "\\n%s", $0
    }
  }'
}

to_epoch() {
  ts="$1"
  [ -z "$ts" ] && return
  epoch=$(printf '%s\n' "$ts" | TZ=UTC0 awk '
    {
      line = $0
      gsub(/Z$/, "", line)
      gsub(/\.[0-9]+/, "", line)
      gsub(/T/, " ", line)
      n = split(line, parts, /[- :]/)
      if (n < 6) {
        exit 1
      }
      year = parts[1] + 0
      month = parts[2] + 0
      day = parts[3] + 0
      hour = parts[4] + 0
      minute = parts[5] + 0
      second = parts[6] + 0
      tspec = sprintf("%04d %02d %02d %02d %02d %02d", year, month, day, hour, minute, second)
      epoch = mktime(tspec)
      if (epoch == 0) {
        exit 1
      }
      print epoch
    }
  ' 2>/dev/null || true)
  if [ -n "$epoch" ]; then
    printf '%s' "$epoch"
  fi
}

# Ensure required binaries exist before continuing.
ensure_binary curl
ensure_binary kubectl
ensure_binary awk
ensure_binary grep

NAMESPACE_REGEX="${NAMESPACE_REGEX:-.*}"
NAMESPACE_DENYLIST_PATH="${NAMESPACE_DENYLIST_PATH:-}"
MAX_NAMESPACE_AGE_HOURS=${MAX_NAMESPACE_AGE_HOURS:-26}
ALERT_MODE="${ALERT_MODE:-slack}"
DRY_RUN="${DRY_RUN:-false}"
ALERT_SILENT_ON_EMPTY="${ALERT_SILENT_ON_EMPTY:-true}"
SLACK_USERNAME="${SLACK_USERNAME:-namespace-janitor}"
SLACK_ICON_EMOJI="${SLACK_ICON_EMOJI:-:wastebasket:}"
ALERT_EMAIL_SUBJECT="${ALERT_EMAIL_SUBJECT:-Namespace cleanup report}"

now_epoch=$(date -u +%s)
deleted_file=$(mktemp)
failed_file=$(mktemp)
namespace_list_file=$(mktemp)
denylist_file=""
trap 'rm -f "$deleted_file" "$failed_file" "$namespace_list_file" ${denylist_file:-}' EXIT INT TERM

deleted_count=0
failed_count=0

denylist_patterns_loaded=false

load_denylist() {
  [ -z "$NAMESPACE_DENYLIST_PATH" ] && return
  if [ ! -f "$NAMESPACE_DENYLIST_PATH" ]; then
    log ERROR "Denylist file not found: $NAMESPACE_DENYLIST_PATH"
    exit 1
  fi
  denylist_file=$(mktemp)
  while IFS= read -r raw || [ -n "$raw" ]; do
    trimmed=$(trim_whitespace "${raw%%#*}")
    [ -z "$trimmed" ] && continue
    printf '%s\n' "$trimmed" >> "$denylist_file"
  done < "$NAMESPACE_DENYLIST_PATH"
  if [ -s "$denylist_file" ]; then
    lines=$(wc -l < "$denylist_file" | tr -d '[:space:]')
    log INFO "Loaded ${lines} denylist pattern(s)"
    denylist_patterns_loaded=true
  else
    log INFO "Denylist file provided but no usable entries found"
  fi
}

is_denied_namespace() {
  candidate="$1"
  if [ "$denylist_patterns_loaded" = "false" ]; then
    return 1
  fi
  if printf '%s\n' "$candidate" | grep -Eq -f "$denylist_file"; then
    return 0
  fi
  return 1
}

build_report() {
  printf 'Namespace janitor report (regex=%s, cutoff=%sh)\n' "$NAMESPACE_REGEX" "$MAX_NAMESPACE_AGE_HOURS"
  if [ -s "$deleted_file" ]; then
    printf 'Deleted:\n'
    cat "$deleted_file"
  fi
  if [ -s "$failed_file" ]; then
    printf 'Failed deletions:\n'
    cat "$failed_file"
  fi
  if [ ! -s "$deleted_file" ] && [ ! -s "$failed_file" ]; then
    printf 'No namespaces required cleanup.\n'
  fi
}

send_slack_alert() {
  require_env SLACK_WEBHOOK_URL "Slack Incoming Webhook URL"
  text=$(build_report)
  payload=$(printf '{"text":"%s","username":"%s","icon_emoji":"%s"}' \
    "$(json_escape "$text")" \
    "$(json_escape "$SLACK_USERNAME")" \
    "$(json_escape "$SLACK_ICON_EMOJI")")
  curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null
}

send_email_alert() {
  require_env ALERT_EMAIL_ENDPOINT "HTTP endpoint that triggers an email"
  require_env ALERT_EMAIL_TO "Comma separated recipients"
  body=$(build_report)
  payload=$(printf '{"to":"%s","subject":"%s","body":"%s"}' \
    "$(json_escape "$ALERT_EMAIL_TO")" \
    "$(json_escape "$ALERT_EMAIL_SUBJECT")" \
    "$(json_escape "$body")")
  curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$ALERT_EMAIL_ENDPOINT" >/dev/null
}

load_denylist

log INFO "Scanning namespaces matching regex: ${NAMESPACE_REGEX}"

kubectl get namespaces \
  -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.creationTimestamp}{"\n"}{end}' \
  > "$namespace_list_file"

while IFS=' ' read -r ns_name creation_ts || [ -n "$ns_name" ]; do
  [ -z "$ns_name" ] && continue
  [ -z "$creation_ts" ] && continue
  if is_denied_namespace "$ns_name"; then
    log INFO "Skipping namespace $ns_name because it matches the denylist"
    continue
  fi
  if ! printf '%s\n' "$ns_name" | grep -Eq "$NAMESPACE_REGEX"; then
    continue
  fi
  created_epoch=$(to_epoch "$creation_ts")
  if [ -z "$created_epoch" ]; then
    log ERROR "Unable to parse creationTimestamp for namespace $ns_name"
    continue
  fi
  age_hours=$(( (now_epoch - created_epoch) / 3600 ))
  if [ "$age_hours" -lt 0 ]; then
    age_hours=0
  fi
  if [ "$age_hours" -lt "$MAX_NAMESPACE_AGE_HOURS" ]; then
    continue
  fi
  log INFO "Namespace $ns_name is ${age_hours}h old (threshold ${MAX_NAMESPACE_AGE_HOURS}h)"
  if [ "$DRY_RUN" = "true" ]; then
    printf ' - %s (%sh) [dry-run]\n' "$ns_name" "$age_hours" >> "$deleted_file"
    deleted_count=$((deleted_count + 1))
    continue
  fi
  if kubectl delete namespace "$ns_name" --wait=false; then
    printf ' - %s (%sh)\n' "$ns_name" "$age_hours" >> "$deleted_file"
    deleted_count=$((deleted_count + 1))
  else
    printf ' - %s (%sh)\n' "$ns_name" "$age_hours" >> "$failed_file"
    failed_count=$((failed_count + 1))
    log ERROR "Failed to delete namespace $ns_name"
  fi
done < "$namespace_list_file"

if [ "$deleted_count" -eq 0 ] && [ "$failed_count" -eq 0 ]; then
  log INFO "No namespaces exceeded ${MAX_NAMESPACE_AGE_HOURS}h"
  if [ "$ALERT_SILENT_ON_EMPTY" = "true" ]; then
    exit 0
  fi
fi

case "$ALERT_MODE" in
  slack)
    send_slack_alert
    ;;
  email)
    send_email_alert
    ;;
  none)
    log INFO "Alerts disabled (ALERT_MODE=none)"
    ;;
  *)
    log ERROR "Unsupported ALERT_MODE: ${ALERT_MODE}"
    exit 1
    ;;
esac
