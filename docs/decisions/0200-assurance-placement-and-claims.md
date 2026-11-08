# Assurance stays an example for now; a claim is a health reading, never a required check

**Status:** Proposed. The owner accepts it. Records the owner decisions of 2026-11-08 on `examples/assurance`.
Date: 2026-11-08.

## Context

The Assurance bluebook (`examples/assurance/bluebook/assurance.bluebook`) judges whether recorded evidence
satisfies a claim (`Claim`, outcome `satisfied`, `violated` or `inconclusive`), and holds a `Deployment` until
every claim it requires is satisfied (`RequiredClaim`, one entity per claim). The pipeline now wants to state
claims about itself: how long CI takes, how long main stays red, how long a landing waits, how much disk is
free. Five questions followed: where Assurance lives, how a claim relates to a required check, when
evidence is recorded, what unit and limit each pipeline claim carries, and which side of the bluebook and
hecksagon line each part falls on.

## Decision

1. **Assurance lives at `examples/assurance` and is not a framework member yet.** The architect's advice is to
   keep it separate until a second consumer exists. The framework-member decision is revisited after the
   first pipeline claims run, when the standalone repository is archived.

2. **A `RequiredClaim` row per (deployment, claim); the pair is the identity.** A deployment names a claim
   once, and a repeat is refused. (The owner's wording was "Requirement row"; the bluebook already uses
   `Requirement` for a value object on `Claim`, so the row keeps its bluebook name, `RequiredClaim`.)

3. **Evidence has no expiry yet.** The commit sha and the run id go in the evidence scope (`Claim.scope`),
   so a reader can tell which commit and which run a measurement describes. `Claim.Record` replaces the
   measurement and scope and resets the outcome to `inconclusive`, so the newest evidence is the only
   evidence a claim holds; earlier measurements stay in the event log. An expiry is a later decision.

4. **When evidence is recorded.** A claim verified from CI records on a CI-completed event. A claim verified
   locally records on a `sweep.tick` step.

5. **No coupling between claims and `RequiredCheck`.** A claim about the pipeline is a health reading. None of
   them describes one sha, and a commit is certified by its own check runs.
   A `Deployment` gates a release or a promotion only on a claim named for that deployment; no claim
   joins or replaces a `RequiredCheck` row.

6. **Units are whole integers.** Seconds for CI wall time and landing wait. Minutes for ages and red
   durations. MB for disk.

7. **Limits.** Each value is marked as owner-set or as a placeholder.

   | Claim | Direction | Limit | Status |
   |---|---|---|---|
   | `main_red_minutes` | at_most | 60 | placeholder |
   | `landing_queue_wait_seconds` | at_most | 300 | placeholder |
   | `commit_to_green_minutes` | at_most | 20 | placeholder |
   | `ci_wall_seconds` | at_most | 180 | owner-set |
   | `disk_free_mb` | at_least | 60000 | owner-set |

   - **Disk.** 60000 MB is DiskSpace's rising line (`rising_free_gb: 60` in `lib/hecks/hecks/hecks.world`).
     The DiskSpace world setting owns the number; the claim's limit is read from it and not typed a second
     time, and the verifier converts GB to MB. DiskSpace's own level stays the gauge, and pipeline-pressure
     takes the DiskSpace level, not the disk claim, so nothing counts twice.
   - **Push nudge.** The `push_nudge` world setting owns 15 commits and 6 hours. A claim over it reads the
     setting, and the verifier converts hours to 360 minutes. No claim on it is declared until one is needed.

8. **Bluebook and hecksagon.** Claim and `Deployment` rules (limits, directions, outcomes, what holds a
   release) are bluebook. The verifiers that read GitHub, git, the disk and the landing queue are adapters
   behind hecksagon ports and never appear in the bluebook. ADR 0080 section 10 (adapter guarantees with
   conformance suites) is how a verifier is held to account: each declares what it guarantees and runs the
   shared conformance suite.

## Consequences

- No bluebook, hecksagon or code changes with this record; it fixes the decisions the first pipeline claims
  build on.
- The three placeholder limits are replaced by owner-set values after the first claims have run.
- Promoting Assurance to a framework member is a separate record, written after the first pipeline claims run.
