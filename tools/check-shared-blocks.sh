#!/usr/bin/env bash
#
# Fail when the duplicated regions of the two coding-agent plugins drift.
#
# Kong streaming custom plugins (Konnect Dedicated Cloud Gateways, Gateway
# 3.15+) accept exactly two files per plugin — handler.lua and schema.lua —
# and cannot require() a sibling module. The request path and the config
# fields are therefore copied into both straiker-coding-agent-buffered and
# straiker-coding-agent-streaming instead of being shared. Copies drift, and
# a drift between the two enforcement paths is silent in production: a route
# would be protected or not depending on which variant it happens to use.
# This check is what stops that.
#
# Each duplicated region is delimited by marker lines that are themselves
# identical in both files:
#
#   -- >>> BEGIN SHARED CORE <<<     ... -- >>> END SHARED CORE <<<
#   -- >>> BEGIN SHARED FIELDS <<<   ... -- >>> END SHARED FIELDS <<<
#
# Usage: scripts/check-shared-blocks.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$ROOT/kong/plugins/straiker-coding-agent-buffered"
B="$ROOT/kong/plugins/straiker-coding-agent-streaming"

status=0

# extract <file> <block-name> -> the lines strictly between the markers
extract() {
  awk -v name="$2" '
    $0 == "-- >>> BEGIN " name " <<<" { inside = 1; seen = 1; next }
    $0 == "-- >>> END "   name " <<<" { inside = 0; next }
    inside { print }
    END { if (!seen) exit 3 }
  ' "$1"
}

compare() {
  local file="$1" block="$2" a b
  if ! a="$(extract "$A/$file" "$block")"; then
    echo "FAIL  $file: no '$block' block in straiker-coding-agent-buffered" >&2
    status=1
    return
  fi
  if ! b="$(extract "$B/$file" "$block")"; then
    echo "FAIL  $file: no '$block' block in straiker-coding-agent-streaming" >&2
    status=1
    return
  fi
  if [ "$a" = "$b" ]; then
    echo "ok    $file: $block identical ($(printf '%s\n' "$a" | wc -l | tr -d ' ') lines)"
    return
  fi
  echo "FAIL  $file: $block differs between the two coding-agent plugins" >&2
  diff -u \
    --label "straiker-coding-agent-buffered/$file"  <(printf '%s\n' "$a") \
    --label "straiker-coding-agent-streaming/$file" <(printf '%s\n' "$b") >&2 || true
  status=1
}

compare handler.lua "SHARED CORE"
compare schema.lua  "SHARED FIELDS"

# Streaming custom plugins ship only these two files per plugin.
for dir in "$ROOT"/kong/plugins/*/; do
  extra="$(find "$dir" -type f ! -name handler.lua ! -name schema.lua)"
  if [ -n "$extra" ]; then
    echo "FAIL  $(basename "$dir") has files Kong cannot stream:" >&2
    echo "$extra" >&2
    status=1
  fi
done

# Both checks below read code only. Lua line comments are stripped first so a
# prose mention of require() in a header comment is not a finding.
uncomment() { sed -e 's/--.*$//' "$1"; }

# schema.lua must not require() anything — Konnect rejects such a schema.
for schema in "$ROOT"/kong/plugins/*/schema.lua; do
  if uncomment "$schema" | grep -qE '(^|[^[:alnum:]_.])require[[:space:]]*[("]'; then
    echo "FAIL  ${schema#"$ROOT/"} calls require(); Konnect rejects such a schema" >&2
    uncomment "$schema" | grep -nE '(^|[^[:alnum:]_.])require[[:space:]]*[("]' >&2
    status=1
  fi
done

# handler.lua must not require() a sibling plugin module — only handler.lua and
# schema.lua are streamed, so kong.plugins.<anything> resolves to nothing.
for handler in "$ROOT"/kong/plugins/*/handler.lua; do
  if uncomment "$handler" | grep -qE 'require[[:space:]]*[("][^"]*kong\.plugins\.'; then
    echo "FAIL  ${handler#"$ROOT/"} requires a sibling plugin module" >&2
    uncomment "$handler" | grep -nE 'require[[:space:]]*[("][^"]*kong\.plugins\.' >&2
    status=1
  fi
done

[ "$status" -eq 0 ] && echo "All shared blocks in sync; plugin layout is streamable."
exit "$status"
