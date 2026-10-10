# A box roll names its restore point before it changes anything

**Status:** Accepted — implemented in the generated `deploy-box.sh`. Date: 2026-10-10.

## Context

A roll that mints a new era is a one-way door: the journal gains an edge and a new era's head, and rolling the image back afterwards forks the journal. The way back is the database, restored to the moment before the mint. Agents have taken that anchor by hand, as a manual RDS snapshot named `<site>-pre-<change>-era-<date>`, and deleted it by hand once the roll settled. Nothing in the deploy asked for it, recorded it, or noticed when it was missing. A manual snapshot also keeps costing for as long as it is kept, and a snapshot of an instance shared by several sites rewinds all of them.

The shared instance keeps continuous backups for seven days (`BackupRetentionDays` in the shared-database template). A point-in-time restore of that instance to the second before a roll is the same anchor, and it uses backups the instance already keeps.

## Decision

1. **Every box roll names its restore point first.** After it has read the RDS endpoint and found the box, and before the log capture or any command reaches the box, `deploy-box.sh` reads the instance's `BackupRetentionPeriod` and `LatestRestorableTime`, and prints the instance, the moment the roll started, and the `restore-db-instance-to-point-in-time` command that returns to it. The text lands in the `BoxRoll` record's report. The instance is the first label of the endpoint, so no stack output is added.
2. **It is every roll, not only an era mint.** The step is a read, it costs nothing, and the roll cannot tell in advance whether the new image mints. A later roll whose era differs from the one before it already shows in the post-roll era check.
3. **A roll with no usable anchor is refused.** Exit 43 when the backups cannot be read, or are kept fewer days than `MIN_BACKUP_RETENTION_DAYS` (default 3, the settle window of a mint). `SKIP_RESTORE_ANCHOR=1` rolls without one and says so.
4. **Side.** The exit code and its meaning are bluebook (`BoxRoll.Run`, `Statuses::BOX_STATUS`). The AWS call is the generated script, an adapter detail. No new aggregate: the anchor is text in the existing report.

## Consequences

- A roll against an instance that keeps no backups, or one the deploying role cannot describe (`rds:DescribeDBInstances`), now stops with 43 instead of rolling. The escape is named in the message.
- The restore creates a new instance. Pointing the sites back at it, and the shared-instance blast radius (a restore rewinds every site on it), stay a decision for the person at the keyboard.
- Not done here: recording the anchor as a field of its own, comparing the era before the roll with the era after it, and listing the old era's `expected-era` entry for removal once smoke is green. The header of `expected-era` still carries that last step by hand.
- Generated scripts in consuming repositories change on their next `hecks deploy project`; each repository's drift gate shows it.
