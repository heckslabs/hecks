# identified_by keying — corrected diagnosis (session 5, 2026-06-17)

## The correction (I had this wrong mid-session)
I claimed `identified_by` was systemically broken and that awareness only
worked via a `default:` workaround. **Wrong.** Keying works in production.
The confusion came from testing via the single-bluebook-FILE dispatch path,
which has its OWN bug that misled every isolated test this session.

## What is actually true (empirically verified)
- **Directory dispatch keys correctly.** `storehouse <dir> Agg.Make name=alpha`
  then `name=beta` -> 2 rows, ids [alpha, beta]. ✓
- **Live proof:** `~/.heki/hecks/conductor/worker.heki` has 4 distinct
  natural-key ids (bugcheck-w, proof-1, test-worker-1, …). Keying is live.
- **Repo construction is correct in BOTH paths:** `Runtime::boot_with_data_dir`
  (mod.rs:476) passes `agg.identified_by.clone()` to `LazyRepository::new`
  (mod.rs:497) ; `boot()` = `boot_with_data_dir(_, None)`. RULED OUT as the
  bug site.
- `id_for_command` (repository.rs:191) : `if let Some(Value::Str(s)) =
  attrs.get(key) { return s }` else singleton-fallback (store.len()==1) else
  mint counter. Correct logic IF attrs carries the key as Value::Str.

## BUG A — single-file dispatch ignores identified_by (dev path)
Repro : `storehouse /tmp/x.bluebook Dom::Agg.Make name=alpha` ; again
`name=beta` -> 1 row, id "1" (beta overwrote alpha via singleton fallback).
Same bluebook via a DIRECTORY -> 2 correctly-keyed rows. Since repo
construction is ruled out, the divergence is upstream : either the single-file
parse path does not populate `agg.identified_by`, or the `<file> <FQN>` CLI
branch (main.rs : the legacy `args[1].contains('.')` / len>=3 file path,
NOT `dispatch_hecksagon` which the directory path uses, main.rs:3778) routes
to a dispatch entry that drops the id attr before id_for_command. NEEDS a
careful trace of the file-branch dispatch entry vs dispatch_hecksagon ; do
NOT patch blind — two fix hypotheses were already falsified.
Impact : DEV/TEST ONLY (production uses directory dispatch). But it silently
lies in isolated bluebook tests — high-value to fix for testing honesty.
TESTING LESSON : isolate bluebook tests against a one-file DIRECTORY, never a
bare file, or the result is wrong.

## BUG B — writers that don't pass the natural key (production accretion)
Voice (4 rows id 1,3… name:[]), SpeechStream (id 19198), ProcessSentinel
(process_name:[]) accrete auto-id rows on the CORRECT path because their
WRITER never supplies the key : `Voice.Speak` is dispatched (Stop hook) with
`text=` only, no `name=`. The fix is at the WRITER/dispatch site (supply
name=miette / name=stream / the process_name), or a `default:` on the
identity attr (the awareness pattern — which is a legitimate fix, not a
workaround for a broken kernel). Distinct from BUG A.

## Recommendation
Both real, neither is an end-of-session blind kernel patch. BUG A : fix in a
fresh pass with a clean trace of the file-dispatch branch. BUG B : mechanical
(default: on the identity attr, awareness-style) per cell — safe, but the
live cells (Voice) need the restart/clear discipline awareness used.
