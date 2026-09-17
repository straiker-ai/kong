#!/usr/bin/env bash
#
# Fail when the plugin stops being streamable.
#
# Kong streaming custom plugins (Konnect Dedicated Cloud Gateways, Gateway
# 3.15+) accept exactly two files per plugin — handler.lua and schema.lua —
# with no sibling modules and no require() in the schema. Nothing at runtime
# re-checks that: a third file or a stray require() installs fine as a rock and
# into a Docker image, and only fails when someone uploads to a DCG, which is
# the furthest possible point from the change that caused it.
#
# Until v0.12.0 this script also kept the duplicated regions of the two
# coding-agent plugins byte-identical. There is one plugin now, so the copies
# and the drift they could develop are both gone.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

# Streaming custom plugins ship only these two files per plugin.
for dir in "$ROOT"/kong/plugins/*/; do
  name="$(basename "$dir")"
  extra="$(find "$dir" -type f ! -name handler.lua ! -name schema.lua)"
  if [ -n "$extra" ]; then
    echo "FAIL  $name has files Kong cannot stream:" >&2
    echo "$extra" >&2
    status=1
  else
    echo "ok    $name: handler.lua + schema.lua only"
  fi
  for required in handler.lua schema.lua; do
    if [ ! -f "$dir$required" ]; then
      echo "FAIL  $name is missing $required" >&2
      status=1
    fi
  done
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
  else
    echo "ok    ${schema#"$ROOT/"}: no require()"
  fi
done

# handler.lua must not require() a sibling plugin module — only handler.lua and
# schema.lua are streamed, so kong.plugins.<anything> resolves to nothing.
for handler in "$ROOT"/kong/plugins/*/handler.lua; do
  if uncomment "$handler" | grep -qE 'require[[:space:]]*[("][^"]*kong\.plugins\.'; then
    echo "FAIL  ${handler#"$ROOT/"} requires a sibling plugin module" >&2
    uncomment "$handler" | grep -nE 'require[[:space:]]*[("][^"]*kong\.plugins\.' >&2
    status=1
  else
    echo "ok    ${handler#"$ROOT/"}: no sibling require()"
  fi
done

[ "$status" -eq 0 ] && echo "Plugin layout is streamable."
exit "$status"
