#!/usr/bin/env bash
# Zero-downtime proof: hammer the site while Jenkins switches traffic.
# Usage: scripts/loadtest.sh [url]     (Ctrl+C to stop and print the summary)
URL=${1:-http://localhost:${HTTP_PORT:-8088}/health}
ok=0; fail=0
trap 'echo; echo "SUMMARY: ok=$ok failed=$fail"; exit 0' INT TERM
while true; do
  resp=$(curl -s --max-time 2 -w '|%{http_code}' "$URL" || echo '|000')
  code=${resp##*|}; body=${resp%|*}
  ver=$(echo "$body" | grep -oE '"(version|color)": ?"[^"]*"' | tr '\n' ' ')
  if [ "$code" = 200 ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
  printf '%s %s %s\n' "$(date +%T)" "$code" "$ver"
  sleep 0.1
done
