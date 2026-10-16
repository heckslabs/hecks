# A release bump inherits its base's certification

**Status:** Accepted — implemented in `CiGate` `release_only`, `Hecks::Tools::ReleaseOnly` and the `ci.yml` jobs `release_only`, `inherit_certification` and `release_consistency`. Date: 2026-10-16.

## Context

`stable` moves only onto a commit on which every `RequiredCheck` passed, judged from the check runs of that exact commit, never from "`main` was green about then". A release bump edits seven files by hand (the version, the changelog, two README lines, one lockfile line, the host's release marker and the client package) and changes no behavior, yet it ran the whole suite again: every job, for the same code the previous commit had already certified.

Skipping CI for it is not an option, because a commit with no check runs is never certified, and `release.yml` releases only a commit `stable` contains. What is wanted is a commit that runs no heavy job and is still certified by check runs on its own sha.

The attestation notes already do half of this. A signed note keyed by tree tells each detector job to skip its heavy job, and a skipped job reports success. A bump changes the tree, so no note matches.

## Decision

1. **A release bump inherits the certification of its base.** A change is a release bump when it touches at least one file, every file it touches is a `ReleaseFile` row of the Vocabulary chapter, and every line it adds or removes in a file matches that row's `lines` pattern (empty admits any line). The rows are the only list of release files.
2. **The base must be certified.** The base is the commit the change is measured against (a push's `before`, a pull request's base). Every `RequiredCheck` row not marked `runs: always` must have its latest check run on the base succeed or be skipped.
3. **The gate is a `CiGate` row.** `release_only` has mode `release_only`; `hecks decide_ci_gate gate=release_only` answers `touched=false` only when both conditions hold. Everything it cannot confirm (no base, a failed diff, an unreadable API answer) answers `touched=true`, so the suite runs.
4. **Inheriting writes an attestation.** When the gate answers `touched=false`, `inherit_certification` writes the signed note for this tree through the existing `write-attestation` action. The detectors in front of each heavy job find it and skip, so each required check reports success on this exact sha without its job running. The `_impl` calls and the fuzzing detector wait for that job (`needs:`, with `if: !cancelled()` so a skipped or failed job lets the suite run).
5. **A consistency check always runs.** `release_consistency` is a `RequiredCheck` with `runs: always`. It runs the specs that hold the files a bump edits to each other (README, client package, host release marker, changelog, docs, release workflow), so a half-done bump is not certified.

## Consequences

- A release-only commit on a certified base finishes in the gate, one attestation write and the consistency job, in place of the whole suite.
- The guarantee is unchanged: every commit reachable from `stable` was certified by check runs on its exact sha. The checks that a bump inherits did not run on that sha, but they passed on a commit whose only difference is the release lines the rows list, and `release_consistency` ran on it.
- A line the rows do not list, in any file, makes the commit an ordinary one. Widening what a bump may touch is a new row, reviewed as a diff.
- Every run now waits for the `release_only` job before its detectors start. It is one checkout and one launcher call, comparable to the existing `runtime_changed` detector.
- The `stable` ruleset gains `release_consistency` as a required context (`hecks project_lanes`). Applying a ruleset to GitHub is the existing separate, confirmed step.
- Not done here: inheriting for a commit whose parent is itself an inherited bump beyond the base's own check runs (they are read the same way, and report success), and exempting other mechanical commits.
