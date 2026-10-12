#!/usr/bin/env bash
# Blue-green controller.
#   switch.sh init <tag>           first-time bootstrap (both colors + worker run <tag>, blue is live)
#   switch.sh deploy-idle <tag>    deploy <tag> to the IDLE color and wait until healthy
#   switch.sh switch               point Nginx at the idle color (graceful reload)
#   switch.sh verify <tag>         check /health THROUGH nginx reports version <tag>
#   switch.sh deploy-worker <tag>  roll the background worker to <tag>
#   switch.sh rollback             point Nginx back at the other color (still running)
#   switch.sh status               show live/idle color and tags
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=nginx/active_upstream.conf
STATE=.deploy.env          # remembers BLUE_TAG / GREEN_TAG / WORKER_TAG (gitignored)
LOG=deploy.log             # deployment audit trail (gitignored)
ACTOR=${DEPLOY_ACTOR:-${USER:-unknown}}
ENVNAME=${DEPLOY_ENV:-unknown}

[ -f .env ] || { echo "ERROR: .env not found (copy .env.example)" >&2; exit 1; }
touch "$STATE" "$LOG"
DC="docker compose --env-file .env --env-file $STATE"

active() {
  if [ -f "$UPSTREAM" ]; then
    grep -oE 'api-(blue|green)' "$UPSTREAM" | head -n1 | cut -d- -f2
  else
    echo none
  fi
}
idle() { if [ "$(active)" = blue ]; then echo green; else echo blue; fi; }

set_var() {   # set_var KEY VALUE  -> idempotent update of $STATE
  sed -i "/^$1=/d" "$STATE"
  echo "$1=$2" >> "$STATE"
}

log_event() {
  local msg="$*" line url
  line="$(date -Is) env=$ENVNAME actor=$ACTOR $msg"
  echo "$line" >> "$LOG"
  echo "$line"
  url=$(grep -E '^DEPLOY_WEBHOOK_URL=' .env | cut -d= -f2- || true)
  if [ -n "${url:-}" ]; then
    curl -s -m 5 -X POST -H 'Content-Type: application/json' \
      -d "{\"text\": \"$msg (env=$ENVNAME actor=$ACTOR)\"}" "$url" >/dev/null || true
  fi
}

wait_healthy() {  # wait_healthy blue|green
  local svc="api-$1" cid status
  for _ in $(seq 1 40); do
    cid=$($DC ps -q "$svc" || true)
    if [ -n "$cid" ]; then
      status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")
      [ "$status" = healthy ] && return 0
    fi
    sleep 3
  done
  echo "ERROR: $svc never became healthy" >&2
  $DC logs --tail 30 "$svc" >&2 || true
  return 1
}

point_to() {  # point_to blue|green  (edit IN PLACE, validate, reload; restore on failure)
  local prev
  prev=$(cat "$UPSTREAM")
  echo "upstream api_backend { server api-$1:5000; }" > "$UPSTREAM"
  if ! $DC exec -T nginx nginx -t || ! $DC exec -T nginx nginx -s reload; then
    echo "$prev" > "$UPSTREAM"
    echo "ERROR: nginx reload failed, previous upstream restored" >&2
    return 1
  fi
}

cmd=${1:-}
case "$cmd" in
  init)
    TAG=${2:?usage: switch.sh init <tag>}
    if [ -n "$($DC ps -q nginx 2>/dev/null)" ]; then
      echo "stack already running; skipping init"; exit 0
    fi
    echo "upstream api_backend { server api-blue:5000; }" > "$UPSTREAM"
    set_var BLUE_TAG "$TAG"; set_var GREEN_TAG "$TAG"; set_var WORKER_TAG "$TAG"
    $DC up -d
    wait_healthy blue
    wait_healthy green
    log_event "INIT stack with tag=$TAG, live=blue"
    ;;

  deploy-idle)
    TAG=${2:?usage: switch.sh deploy-idle <tag>}
    if [ -z "$($DC ps -q nginx 2>/dev/null)" ]; then
      "$0" init "$TAG"
    fi
    COLOR=$(idle)
    echo "live=$(active) idle=$COLOR -> deploying tag=$TAG to $COLOR"
    set_var "$(echo "$COLOR" | tr a-z A-Z)_TAG" "$TAG"
    $DC pull "api-$COLOR"
    $DC up -d --no-deps "api-$COLOR"
    wait_healthy "$COLOR"
    log_event "DEPLOYED tag=$TAG to idle color=$COLOR (live=$(active))"
    ;;

  switch)
    NEW=$(idle); OLD=$(active)
    point_to "$NEW"
    log_event "SWITCHED traffic $OLD -> $NEW"
    ;;

  verify)
    EXPECTED=${2:?usage: switch.sh verify <tag>}
    body=""
    for _ in $(seq 1 10); do
      body=$($DC exec -T nginx wget -qO- http://localhost/health 2>/dev/null || true)
      if echo "$body" | grep -Eq "\"version\": ?\"$EXPECTED\""; then
        echo "VERIFIED via nginx: $body"
        log_event "VERIFIED tag=$EXPECTED live=$(active)"
        exit 0
      fi
      sleep 2
    done
    log_event "VERIFY FAILED expected=$EXPECTED got='${body:-<no response>}'"
    exit 1
    ;;

  deploy-worker)
    TAG=${2:?usage: switch.sh deploy-worker <tag>}
    set_var WORKER_TAG "$TAG"
    $DC pull worker
    $DC up -d --no-deps worker
    log_event "WORKER updated to tag=$TAG"
    ;;

  rollback)
    TARGET=$(idle)
    point_to "$TARGET"
    log_event "ROLLBACK traffic now on $TARGET"
    ;;

  status)
    echo "live : $(active)"
    echo "idle : $(idle)"
    echo "tags :"; sed 's/^/  /' "$STATE"
    ;;

  *)
    sed -n '2,10p' "$0"; exit 1 ;;
esac
