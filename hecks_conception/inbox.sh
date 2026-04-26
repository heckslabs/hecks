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
    # Optional --wish=<id> flag — names the DreamWish this inbox item
    # is filing. The inbox row carries wish_id ; after the append we
    # dispatch DreamWish.MarkFiled so the wish exits the unfiled pool.
    # Filing is the receipt I was waiting for ; no implementation
    # required for me to dream of something else (i98 follow-up).
    wish_id=""
    args=()
    for a in "$@"; do
      case "$a" in
        --wish=*) wish_id="${a#--wish=}" ;;
        *)        args+=("$a") ;;
      esac
    done
    set -- "${args[@]}"
    priority="$1"; body="$2"
    if [ -z "$priority" ] || [ -z "$body" ]; then
      echo "usage: inbox.sh add [--wish=<id>] <priority> <body>" >&2; exit 1
    fi
    ref=$(next_ref)
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    if [ -n "$wish_id" ]; then
      "$HECKS" heki append "$HEKI" \
        ref="$ref" priority="$priority" status=queued posted_at="$now" \
        wish_id="$wish_id" body="$body" \
        >/dev/null
      # Mark the receipt directly via heki upsert. Bypasses the
      # bluebook dispatch path because the runtime's lookup-by-id
      # for non-singleton aggregates currently misroutes (file
      # this as i99). The bluebook still declares the shape ;
      # this is the transitional adapter that actually persists
      # the receipt. Same pattern as inbox itself uses (heki
      # append for collections, not Aggregate.Add dispatch).
      WISH_HEKI="${HECKS_INFO:-$DIR/information}/dream_wish.heki"
      if [ -f "$WISH_HEKI" ]; then
        "$HECKS" heki upsert "$WISH_HEKI" \
          id="$wish_id" status=filed filed_as="$ref" filed_at="$now" \
          >/dev/null 2>&1 || true
      fi
    else
      "$HECKS" heki append "$HEKI" \
        ref="$ref" priority="$priority" status=queued posted_at="$now" body="$body" \
        >/dev/null
    fi

    # Auto-commit + push to main. Two-step durability :
    #
    # 1. Local commit on whatever branch the operator is on. Keeps the
    #    working tree consistent so subsequent commands see the new ref.
    # 2. Push the same heki content to origin/main directly, via a
    #    temporary worktree, so the filing survives even if the local
    #    branch is later abandoned (deleted post-merge with
    #    --delete-branch, force-discarded, etc).
    #
    # Why both : step 1 alone is fragile — the 2026-04-24 morphology
    # filing was made on miette/fix-ci-i67-spec-update AFTER the PR was
    # opened ; the merge with --delete-branch dropped the unmerged
    # filing because it was never pushed. Step 2 closes that hole.
    #
    # Step 2 uses a temp worktree of origin/main so the operator's
    # current branch and uncommitted work are completely undisturbed.
    # The worktree's inbox.heki gets the SAME content the local commit
    # captured (we just `cp` the file across), then commit + push +
    # remove the worktree. ~1 second total ; signed-commit config is
    # inherited from the operator's git config.
    #
    # Failure modes (each prints a loud warning, never silent) :
    #   - not a git checkout : skip both steps
    #   - local commit fails : warn and stop ; don't attempt push
    #   - origin/main fetch fails (offline) : warn ; local commit stands
    #   - worktree dance fails : warn ; the filing rides the local
    #     branch as a fallback (the pre-2026-04-25 behaviour)
    #   - push to main fails (concurrent push, perm error) : warn ;
    #     the filing rides the local branch as a fallback
    if [ -d "$DIR/../.git" ] || git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
      subject=$(printf '%s' "$body" | head -c 60 | tr '\n' ' ')
      if git -C "$DIR" add "$HEKI" >/dev/null 2>&1; then
        if git -C "$DIR" commit -q -m "inbox($ref): $subject" >/dev/null 2>&1; then
          # Step 2 — push to main via a temp worktree. Bail loudly on
          # any failure ; the local commit from step 1 is still durable
          # on the current branch.
          repo_root=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)
          heki_relpath="hecks_conception/information/inbox.heki"
          tmp_wt=$(mktemp -d -t hecks-inbox-push-XXXXXXXX)
          if [ -n "$repo_root" ] && [ -n "$tmp_wt" ] \
             && git -C "$repo_root" fetch origin main --quiet 2>/dev/null \
             && git -C "$repo_root" worktree add --detach --quiet "$tmp_wt" origin/main 2>/dev/null; then
            cp "$HEKI" "$tmp_wt/$heki_relpath"
            ( cd "$tmp_wt" \
              && git add "$heki_relpath" >/dev/null 2>&1 \
              && git commit -q -m "inbox($ref): $subject" >/dev/null 2>&1 \
              && git push --quiet origin HEAD:main 2>/dev/null ) \
              || echo "warning: inbox($ref) push to main failed ; filing is durable on current branch only" >&2
            git -C "$repo_root" worktree remove --force "$tmp_wt" >/dev/null 2>&1
          else
            rm -rf "$tmp_wt" 2>/dev/null
            echo "warning: inbox($ref) push to main skipped (fetch or worktree setup failed) ; filing is durable on current branch only" >&2
          fi
        else
          echo "warning: heki updated but git commit failed for inbox($ref)" >&2
          echo "         stage the file manually to preserve the filing" >&2
        fi
      fi
    fi

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
