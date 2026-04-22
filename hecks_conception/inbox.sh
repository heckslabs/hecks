#!/bin/sh
# inbox.sh — short-ref CLI over hecks_conception/information/inbox.heki
#
# Each inbox record carries two ids:
#   * heki uuid (primary key, 36 chars, opaque)
#   * ref      (sequential, "i42" — what humans type)
#
# Refs are assigned monotonically at add time. They never change once
# assigned; closing or archiving an item leaves the ref pointing at the
# same record so historical references stay valid.
#
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c with
#  native hecks-life heki subcommands per PR #272; retires when shell
#  wrapper ports to .bluebook shebang form (tracked in
#  terminal_capability_wiring plan).]
#
# Usage:
#   inbox.sh add high "body text"          → assigns next ref, prints it
#   inbox.sh list [queued|done|all]        → list with refs (queued by default)
#   inbox.sh show i42                      → full body
#   inbox.sh done i42 "commit sha — note"  → mark done with resolution
#   inbox.sh archive i42                   → move to archive heki

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="$DIR/../hecks_life/target/release/hecks-life"
HEKI="$DIR/information/inbox.heki"

# Look up a record's uuid by its short ref. Prints uuid or empty.
ref_to_uuid() {
  "$HECKS" heki list "$HEKI" --where "ref=$1" --fields id --format tsv 2>/dev/null | head -n1
}

# Compute the next ref by scanning all existing refs (handles both the
# in-order and out-of-order cases — gaps from deleted items are skipped).
next_ref() {
  "$HECKS" heki next-ref "$HEKI" --prefix i --field ref 2>/dev/null
}

cmd="${1:-list}"
shift 2>/dev/null || true

case "$cmd" in
  add)
    priority="$1"; body="$2"
    if [ -z "$priority" ] || [ -z "$body" ]; then
      echo "usage: inbox.sh add <priority> <body>" >&2; exit 1
    fi
    ref=$(next_ref)
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    "$HECKS" heki append "$HEKI" \
      ref="$ref" priority="$priority" status=queued posted_at="$now" body="$body" \
      >/dev/null
    echo "$ref"
    ;;
  list)
    filter="${1:-queued}"
    if [ "$filter" = "all" ]; then
      where_args=""
    else
      where_args="--where status=$filter"
    fi
    # shellcheck disable=SC2086 # word-splitting is intentional for optional --where
    "$HECKS" heki list "$HEKI" $where_args \
        --order priority:enum=high,medium,normal,low \
        --order ref:numeric_ref \
        --fields ref,priority,status,body \
        --format json 2>/dev/null \
      | jq -r '.[] | [
          (.ref // "—"),
          ((.priority // "?") | .[0:6]),
          ((.status // "?") | .[0:8]),
          ((.body // "") | gsub("\n";" ") | .[0:90])
        ] | @tsv' \
      | awk -F'\t' '{ printf "  %5s  [%-6s/%-6s]  %s\n", $1, $2, $3, $4 }'
    ;;
  show)
    ref="$1"
    [ -z "$ref" ] && { echo "usage: inbox.sh show <ref>" >&2; exit 1; }
    uuid=$(ref_to_uuid "$ref")
    [ -z "$uuid" ] && { echo "no item with ref $ref" >&2; exit 1; }
    rec_json=$("$HECKS" heki get "$HEKI" "$uuid" 2>/dev/null)
    printf 'ref:         %s\n' "$(printf '%s' "$rec_json" | jq -r '.ref // ""')"
    printf 'uuid:        %s\n' "$uuid"
    printf 'priority:    %s\n' "$(printf '%s' "$rec_json" | jq -r '.priority // ""')"
    printf 'status:      %s\n' "$(printf '%s' "$rec_json" | jq -r '.status // ""')"
    printf 'posted_at:   %s\n' "$(printf '%s' "$rec_json" | jq -r '.posted_at // ""')"
    completed=$(printf '%s' "$rec_json" | jq -r '.completed_at // ""')
    [ -n "$completed" ] && printf 'completed_at: %s\n' "$completed"
    resolution=$(printf '%s' "$rec_json" | jq -r '.resolution // ""')
    [ -n "$resolution" ] && printf 'resolution:   %s\n' "$resolution"
    printf '\n'
    printf '%s\n' "$(printf '%s' "$rec_json" | jq -r '.body // ""')"
    ;;
  done)
    ref="$1"; resolution="$2"
    [ -z "$ref" ] && { echo "usage: inbox.sh done <ref> [resolution]" >&2; exit 1; }
    uuid=$(ref_to_uuid "$ref")
    [ -z "$uuid" ] && { echo "no item with ref $ref" >&2; exit 1; }
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    "$HECKS" heki upsert "$HEKI" \
      id="$uuid" status=done completed_at="$now" resolution="${resolution:-done}" \
      >/dev/null
    echo "closed $ref"
    ;;
  archive)
    ref="$1"
    [ -z "$ref" ] && { echo "usage: inbox.sh archive <ref>" >&2; exit 1; }
    uuid=$(ref_to_uuid "$ref")
    [ -z "$uuid" ] && { echo "no item with ref $ref" >&2; exit 1; }
    "$HECKS" heki delete "$HEKI" "$uuid" >/dev/null
    echo "archived $ref"
    ;;
  next-ref)
    next_ref
    ;;
  *)
    echo "unknown command: $cmd" >&2
    echo "usage: inbox.sh {add|list|show|done|archive|next-ref}" >&2
    exit 1
    ;;
esac
