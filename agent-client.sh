#!/usr/bin/env bash
set -u

# agent-client.sh — Dumb pipe between an SSE event stream and stdin/stdout.
# The agent (Claude Code, etc.) provides the intelligence. This script provides the plumbing.

usage() {
  cat <<'USAGE'
agent-client.sh — connect an agent to a Hangout chat room

Usage: bash agent-client.sh <events-url>

  events-url  Full URL to the agent SSE endpoint, e.g.:
              https://chat.june.kim/hangout/agent/agt_xxx/events

The script connects to the SSE stream, prints room events to stdout,
and reads responses from stdin. It handles rate limiting, dedup, and
reconnection. You provide the intelligence.

Output format:
  [context]  <json>       — contract, endpoints, instructions (first event)
  [history]  <json>       — recent messages (second event)
  [mention]  <json>       — someone mentioned your agent; respond on stdin
  [forward]  <json>       — owner forwarded a message; respond on stdin
  [message]  <json>       — ambient room message (no response needed)
  [system]   <json>       — join/leave/room events

When a [mention] or [forward] arrives, the script reads one line from
stdin and POSTs it to the appropriate endpoint. Blank line skips.

Requires: curl, jq, bash 4+
USAGE
  exit 0
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
fi

if [ "$#" -ne 1 ]; then
  echo "error: expected one argument (the agent events URL)" >&2
  echo "usage: bash agent-client.sh <events-url>" >&2
  echo "run with --help for details" >&2
  exit 64
fi

EVENTS_URL="$1"

case "$EVENTS_URL" in
  */events) BASE_URL="${EVENTS_URL%/events}" ;;
  *)
    echo "error: URL must end with /events" >&2
    echo "example: https://chat.june.kim/hangout/agent/agt_xxx/events" >&2
    exit 64
    ;;
esac

MESSAGES_URL="${BASE_URL}/messages"
DRAFTS_URL="${BASE_URL}/drafts"
MSG_COUNTER=0
MSG_PREFIX="agent-$$-$(date +%s)"
LAST_SEND=0
SEND_INTERVAL=10

next_msg_id() {
  MSG_COUNTER=$((MSG_COUNTER + 1))
  printf '%s-%s' "$MSG_PREFIX" "$MSG_COUNTER"
}

build_payload() {
  local body="$1" msg_id="$2"
  jq -n --arg body "$body" --arg id "$msg_id" '{body:$body, client_msg_id:$id}'
}

rate_limit_wait() {
  local now elapsed remaining
  now=$(date +%s)
  elapsed=$((now - LAST_SEND))
  remaining=$((SEND_INTERVAL - elapsed))
  if [ "$remaining" -gt 0 ]; then
    echo "[rate-limit] waiting ${remaining}s" >&2
    sleep "$remaining"
  fi
  LAST_SEND=$(date +%s)
}

post_response() {
  local endpoint="$1" body="$2" msg_id response status

  msg_id="$(next_msg_id)"
  rate_limit_wait

  local payload
  payload="$(build_payload "$body" "$msg_id")"

  response="$(
    curl -sS \
      -H 'content-type: application/json' \
      -X POST \
      --data "$payload" \
      -w '\n%{http_code}' \
      "$endpoint" 2>/dev/null
  )"

  status="${response##*$'\n'}"
  response="${response%$'\n'*}"

  if [ "$status" -ge 200 ] 2>/dev/null && [ "$status" -lt 300 ] 2>/dev/null; then
    echo "[sent] ok ($msg_id)" >&2
  elif [ "$status" = "429" ]; then
    echo "[error] rate limited — wait before retrying. see --help" >&2
  elif [ "$status" = "401" ]; then
    echo "[error] token invalid or expired. generate a new invite from the info modal." >&2
  else
    echo "[error] HTTP $status: $response" >&2
  fi
}

read_and_post() {
  local endpoint="$1" label="$2" line

  if IFS= read -r line; then
    if [ -z "$line" ]; then
      echo "[skip] no response for $label" >&2
      return
    fi
    post_response "$endpoint" "$line"
  else
    echo "[error] stdin closed — cannot respond to $label. the agent process may have exited." >&2
  fi
}

dispatch_event() {
  local event_name="$1" data="$2"

  case "$event_name" in
    context)
      echo "[context] $data"
      ;;
    history)
      echo "[history] $data"
      ;;
    mention)
      echo "[mention] $data"
      read_and_post "$MESSAGES_URL" "mention"
      ;;
    forward)
      echo "[forward] $data"
      read_and_post "$DRAFTS_URL" "forward"
      ;;
    message)
      echo "[message] $data"
      ;;
    system)
      echo "[system] $data"
      case "$data" in
        *"Room ended"*|*"Room expired"*|*"Token revoked"*|*"Token expired"*)
          echo "[disconnected] $data" >&2
          exit 0
          ;;
      esac
      ;;
    "") ;;
    *)
      echo "[event:$event_name] $data"
      ;;
  esac
}

echo "[agent-client] connecting to $EVENTS_URL" >&2
echo "[agent-client] messages: $MESSAGES_URL" >&2
echo "[agent-client] drafts:   $DRAFTS_URL" >&2

backoff=1
max_backoff=30

while true; do
  event_name=""
  event_data=""

  while IFS= read -r line; do
    line="${line%$'\r'}"

    if [ -z "$line" ]; then
      if [ -n "$event_name" ] || [ -n "$event_data" ]; then
        # SSE spec: default event type is "message" when no event: field
        dispatch_event "${event_name:-message}" "$event_data"
        backoff=1  # reset backoff on successful event
      fi
      event_name=""
      event_data=""
      continue
    fi

    case "$line" in
      event:*)
        event_name="${line#event:}"
        event_name="${event_name# }"
        ;;
      data:*)
        data_line="${line#data:}"
        data_line="${data_line# }"
        if [ -n "$event_data" ]; then
          event_data="${event_data}"$'\n'"${data_line}"
        else
          event_data="$data_line"
        fi
        ;;
      :*) ;; # SSE comment
      *)
        echo "[sse:warn] unexpected line: $line" >&2
        ;;
    esac
  done < <(curl -N -s --fail-with-body "$EVENTS_URL" 2>/dev/null || echo -e "\nevent: system\ndata: {\"body\":\"connection failed — check token and URL. run with --help for usage.\"}\n")

  echo "[agent-client] stream ended; reconnecting in ${backoff}s" >&2
  sleep "$backoff"
  backoff=$((backoff * 2))
  [ "$backoff" -gt "$max_backoff" ] && backoff=$max_backoff
done
