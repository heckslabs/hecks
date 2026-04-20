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
  "$HECKS" heki read "$HEKI" 2>/dev/null | python3 -c "
import json, sys
ref = '$1'
d = json.load(sys.stdin)
for k, v in d.items():
    if v.get('ref') == ref:
        print(k); break
"
}

# Compute the next ref by scanning all existing refs (handles both the
# in-order and out-of-order cases — gaps from deleted items are skipped).
next_ref() {
  "$HECKS" heki read "$HEKI" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
nums = []
for v in d.values():
    r = v.get('ref', '')
    if r.startswith('i') and r[1:].isdigit():
        nums.append(int(r[1:]))
print(f'i{(max(nums) + 1) if nums else 1}')
"
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
    "$HECKS" heki read "$HEKI" 2>/dev/null | python3 -c "
import json, sys
filt = '$filter'
d = json.load(sys.stdin)
items = []
for v in d.values():
    if filt != 'all' and v.get('status') != filt: continue
    items.append(v)
order = {'high':0, 'medium':1, 'normal':2, 'low':3}
items.sort(key=lambda v: (
    order.get(v.get('priority','normal'), 9),
    int(v.get('ref','i999')[1:]) if v.get('ref','').startswith('i') else 999,
))
for v in items:
    ref = v.get('ref', '—')
    pri = v.get('priority', '?')[:6]
    st  = v.get('status', '?')[:8]
    body = v.get('body', '').replace(chr(10), ' ')[:90]
    print(f'  {ref:>5}  [{pri:6}/{st:6}]  {body}')
"
    ;;
  show)
    ref="$1"
    [ -z "$ref" ] && { echo "usage: inbox.sh show <ref>" >&2; exit 1; }
    uuid=$(ref_to_uuid "$ref")
    [ -z "$uuid" ] && { echo "no item with ref $ref" >&2; exit 1; }
    "$HECKS" heki read "$HEKI" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
v = d.get('$uuid', {})
print(f'ref:         {v.get(\"ref\")}')
print(f'uuid:        $uuid')
print(f'priority:    {v.get(\"priority\")}')
print(f'status:      {v.get(\"status\")}')
print(f'posted_at:   {v.get(\"posted_at\")}')
if v.get('completed_at'): print(f'completed_at: {v.get(\"completed_at\")}')
if v.get('resolution'):   print(f'resolution:   {v.get(\"resolution\")}')
print()
print(v.get('body', ''))
"
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
