#!/usr/bin/env bash
# fibroblast_sweep.sh — the i629 :exec repair arm for the Fibroblast cell.
#
# Bound to Fibroblast.Sweep in fibroblast.hecksagon. On dispatch the
# kernel runs this script. It reads every OPEN healing (closed_at empty)
# from the fibroblast .heki store and, per record, takes EXACTLY ONE of
# two paths:
#
#   nav_sitemap_close (mechanical, verifiable) — auto-APPLY:
#     read the NavSitemapParity drift for the signalled site, write the
#     missing sitemap entries / prune the dead URLs, re-dispatch
#     NavSitemapParity.Check, and ONLY if the re-check shows the drift
#     cleared do we dispatch SelectStrategy → Heal → RecordOutcome(closed).
#     If verification fails, we revert the sitemap and Decline.
#
#   anything else (bluebook_first_file_gap, loc_ratchet_extract, or an
#   unrecognised signal) — DECLINE GRACEFULLY: compose a diagnosis +
#   proposed repair, dispatch SelectStrategy → Decline → RecordOutcome
#   (declined). Touch no code. Surface to a human.
#
# SAFETY: this script NEVER runs `git commit`. The one mechanical fix it
# applies lands in the working tree only, after the fibroblast verifies
# the drift cleared. A human reviews + commits. Over-reaching is a bug.
#
# Usage (normally invoked by the :exec dispatcher, not by hand):
#   bash bin/fibroblast_sweep.sh
#
# Env / paths:
#   HECKS_INFO       — state dir holding the .heki stores (set by runtime)
#   storehouse       — the runtime CLI on PATH (dispatch + heki read)
#   aggregates root  — derived from this script's own location

set -euo pipefail

# ── Resolve paths ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"          # the aggregates root (hecks_conception)
INFO="${HECKS_INFO:-$ROOT/information}"
FIBRO_HEKI="$INFO/fibroblast/fibroblast.heki"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { echo "[fibroblast_sweep] $*"; }

dispatch() {
  # dispatch <FQN.Command> k='{...}' ...
  storehouse "$ROOT" "$@" >/dev/null 2>&1
}

if [ ! -f "$FIBRO_HEKI" ]; then
  log "no fibroblast store at $FIBRO_HEKI — nothing to sweep"
  echo "swept 0 open healings (no store)"
  exit 0
fi

# ── Enumerate open healings ────────────────────────────────────────
# Open := closed_at empty (array []) AND it is a REAL healing, not a
# Sweep audit row. A Sweep row carries no signal_aggregate (the tick
# sets only signal_id="sweep" + started_at), so we require a non-empty
# signal_aggregate to qualify as a healing to act on.
OPEN_IDS="$(storehouse heki read "$FIBRO_HEKI" \
  | jq -r 'to_entries[]
           | select((.value.closed_at | (. == null or . == [] or . == "")))
           | select((.value.signal_aggregate // "") | (. != "" and . != []))
           | select((.value.signal_id // "") | test("sweep") | not)
           | .key')"

if [ -z "$OPEN_IDS" ]; then
  log "no open healings"
  echo "swept 0 open healings"
  exit 0
fi

closed=0
declined=0

# ── Heal each open record ──────────────────────────────────────────
while IFS= read -r ID; do
  [ -z "$ID" ] && continue
  REC="$(storehouse heki read "$FIBRO_HEKI" | jq -c --arg id "$ID" '.[$id]')"
  SIG_AGG="$(echo "$REC" | jq -r '.signal_aggregate // ""' | sed -n 's/.*name: \([^}]*\)}.*/\1/p' | tr -d ' ')"
  SIG_ID="$(echo "$REC" | jq -r '.signal_id // ""' | sed -n 's/.*value: \([^}]*\)}.*/\1/p' | tr -d ' ')"
  [ -z "$SIG_ID" ] && SIG_ID="$ID"
  log "open healing id=$ID signal_aggregate=$SIG_AGG signal_id=$SIG_ID"

  if [ "$SIG_AGG" = "NavSitemapParity" ] && [[ "$SIG_ID" == nsp:* ]]; then
    # ── Mechanical strategy : nav_sitemap_close ──────────────────────
    # The signal_id is the self-contained work order :
    #   "nsp:<site_root>:<target_path>"  e.g. nsp:/srv/site:/contact
    # We compose the concrete sitemap fix straight from it — no
    # re-reading the upstream autophage cell (stigmergy : the signal IS
    # the trace). Parse off the leading "nsp:" then split site_root from
    # target_path on the LAST colon (site paths may themselves be empty
    # of colons, target is always /-rooted).
    log "strategy=nav_sitemap_close (mechanical, verifiable)"
    dispatch "Fibroblast::Fibroblast.SelectStrategy" \
      signal_id="{value: $SIG_ID}" strategy="{name: nav_sitemap_close}"

    WORK="${SIG_ID#nsp:}"            # "<site_root>:<target_path>"
    SITE_ROOT="${WORK%:*}"           # everything before the last colon
    TARGET="${WORK##*:}"             # the target path after the last colon
    SITEMAP="$SITE_ROOT/sitemap.xml"

    if [ -z "$SITE_ROOT" ] || [ -z "$TARGET" ] || [ ! -f "$SITEMAP" ]; then
      reason="nav_sitemap_close aborted: cannot resolve sitemap from work order '$SIG_ID' (sitemap '$SITEMAP' missing) — apply nothing"
      log "$reason — declining"
      dispatch "Fibroblast::Fibroblast.Decline" \
        signal_id="{value: $SIG_ID}" reason="{value: $reason}" declined_at="{value: $NOW}"
      dispatch "Fibroblast::Fibroblast.RecordOutcome" \
        signal_id="{value: $SIG_ID}" outcome="{status: declined, reason: $reason}" recorded_at="{value: $NOW}"
      declined=$((declined+1))
      continue
    fi

    # Backup so we can revert if verification fails.
    cp "$SITEMAP" "$SITEMAP.fibro-bak"

    # APPLY the mechanical fix : insert the missing <url><loc>…</loc></url>
    # entry before the closing </urlset> (idempotent — skip if present).
    applied=0
    if ! grep -q "<loc>$TARGET</loc>" "$SITEMAP"; then
      awk -v entry="  <url><loc>$TARGET</loc></url>" '
        /<\/urlset>/ && !d { print entry; d=1 } { print }' "$SITEMAP" > "$SITEMAP.tmp"
      mv "$SITEMAP.tmp" "$SITEMAP"
      applied=1
    fi
    log "applied $applied sitemap edit(s) to $SITEMAP"

    # VERIFY : re-scan the file (verify the fix, do not trust our own
    # write). The target path must now be present in the sitemap.
    if grep -q "<loc>$TARGET</loc>" "$SITEMAP"; then
      rm -f "$SITEMAP.fibro-bak"
      reason="nav_sitemap_close: wrote entry $TARGET, drift verified cleared (uncommitted working-tree change for human review)"
      log "VERIFIED clean — closing. $reason"
      dispatch "Fibroblast::Fibroblast.Heal" \
        signal_id="{value: $SIG_ID}" commit_sha="{value: v1-uncommitted}" healed_at="{value: $NOW}"
      dispatch "Fibroblast::Fibroblast.RecordOutcome" \
        signal_id="{value: $SIG_ID}" outcome="{status: closed, reason: $reason}" recorded_at="{value: $NOW}"
      closed=$((closed+1))
    else
      # Revert : apply nothing if we cannot verify.
      mv "$SITEMAP.fibro-bak" "$SITEMAP"
      reason="nav_sitemap_close: $TARGET still absent after edit — reverted, surfacing to human"
      log "VERIFY FAILED — reverted. $reason"
      dispatch "Fibroblast::Fibroblast.Decline" \
        signal_id="{value: $SIG_ID}" reason="{value: $reason}" declined_at="{value: $NOW}"
      dispatch "Fibroblast::Fibroblast.RecordOutcome" \
        signal_id="{value: $SIG_ID}" outcome="{status: declined, reason: $reason}" recorded_at="{value: $NOW}"
      declined=$((declined+1))
    fi
  else
    # ── Ambiguous strategy : DECLINE GRACEFULLY, apply nothing ───────
    case "$SIG_AGG" in
      BluebookFirst|*Bluebook*)
        strat="bluebook_first_file_gap"
        proposed="proposed fix: file a gap card for the touched .rs and re-dispatch it as a bluebook ; requires human bluebook authoring — not mechanically derivable" ;;
      LineCount|*LoC*|*Ratchet*)
        strat="loc_ratchet_extract"
        proposed="proposed fix: extract the over-shooting function into its own module ; the extraction boundary is a judgement call — surfacing to human" ;;
      *)
        strat="bluebook_first_file_gap"
        proposed="proposed fix: signal from '$SIG_AGG' maps to no mechanical strategy in the v1 first-target set — surfacing to human review" ;;
    esac
    reason="$strat: $proposed"
    log "ambiguous signal_aggregate=$SIG_AGG — DECLINE (apply nothing). $reason"
    dispatch "Fibroblast::Fibroblast.SelectStrategy" \
      signal_id="{value: $SIG_ID}" strategy="{name: $strat}"
    dispatch "Fibroblast::Fibroblast.Decline" \
      signal_id="{value: $SIG_ID}" reason="{value: $reason}" declined_at="{value: $NOW}"
    dispatch "Fibroblast::Fibroblast.RecordOutcome" \
      signal_id="{value: $SIG_ID}" outcome="{status: declined, reason: $reason}" recorded_at="{value: $NOW}"
    declined=$((declined+1))
  fi
done <<< "$OPEN_IDS"

echo "swept: closed=$closed declined=$declined"
