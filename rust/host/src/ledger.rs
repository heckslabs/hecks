//! Seals over a domain's lineage journal, and the walk that shows the journal was not rewritten.
//!
//! The journal (`hecks_journal_<domain>`) is append-only for an ordinary role: Postgres refuses an
//! update or a delete under row-level security. A seal is evidence against someone the database
//! does not stop. It records the head of a SHA-256 chain over the journal's rows, in a table beside
//! the journal, so a later walk can recompute the chain and compare.
//!
//! Each digest takes the digest before it, over the row as Postgres stores it: `operation`,
//! `aggregate`, `aggregate_id`, then `state` and `mirrors` as their `jsonb` text, where an absent
//! value is distinguished from an empty one. Every field is length-prefixed, so two rows never pack
//! to the same bytes. A seal covers every row up to an ordinal; the first seal follows
//! [`GENESIS`], each later one the head before it.
//!
//! The rows between the last seal and the end of the journal are not covered until the next seal
//! is taken. A seal is taken two ways. A commit takes one once `seal_every` rows (on the host's
//! `LineageConfig`) lie past the last seal, through [`seal_due`]: it lands in the same transaction
//! as the rows it covers, so a crash leaves no rows the ledger claims and the journal lacks, and
//! the one dispatch in every N pays for hashing those N rows. The operator tools (`ledger seal`,
//! `ledger verify`) seal the tail and walk the chain on demand, and never make a write wait.

use crate::store::journal_sql::{journal_table, last_ordinal, quote_ident};
use anyhow::Context;
use sha2::{Digest, Sha256};
use tokio_postgres::{Client, GenericClient};

/// The digest the chain starts from: sixty-four zeros.
pub const GENESIS: &str = "0000000000000000000000000000000000000000000000000000000000000000";

/// How many unsealed lineage rows a commit lets build up before it seals, when nothing says
/// otherwise. A thousand rows hash in a few milliseconds, and at most that many rows wait for a
/// seal.
pub const DEFAULT_SEAL_EVERY: i64 = 1000;

/// The override for the commit-time interval (ADR 0132): a whole number of rows, or `0` to leave
/// sealing to the operator tools.
pub const SEAL_EVERY_VAR: &str = "HECKS_SEAL_EVERY";

/// Reads the commit-time seal interval from the override's value, falling back to
/// [`DEFAULT_SEAL_EVERY`] when it is unset or blank.
///
/// # Errors
///
/// Returns a message naming the variable when its value is not a whole number of rows.
pub fn seal_every(value: Option<&str>) -> Result<Option<i64>, String> {
    let Some(text) = value.map(str::trim).filter(|text| !text.is_empty()) else {
        return Ok(Some(DEFAULT_SEAL_EVERY));
    };
    match text.parse::<i64>() {
        Ok(0) => Ok(None),
        Ok(rows) if rows > 0 => Ok(Some(rows)),
        _ => Err(format!(
            "{SEAL_EVERY_VAR} must be a whole number of rows, or 0 to seal only by hand; got {text:?}"
        )),
    }
}

/// How many journal rows one read pulls, so a long journal is never held whole in memory.
const PAGE: i64 = 5000;

/// One seal: the head of the chain through an ordinal, and the head it followed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Anchor {
    /// The highest journal ordinal the seal covers.
    pub through: i64,
    /// The chain digest at `through`, lowercase hexadecimal.
    pub head: String,
    /// The head of the seal before this one; [`GENESIS`] for the first.
    pub previous: String,
}

/// What a walk found when every seal held.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    /// How many seals the journal carries.
    pub seals: usize,
    /// How many journal rows the walk recomputed.
    pub entries: i64,
    /// How many rows lie after the last seal and so are not yet covered.
    pub unsealed: i64,
}

/// The result of walking the chain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Finding {
    /// Every seal followed the one before it and matched the journal.
    Verified(Report),
    /// The chain could not be shown intact, with the reason.
    Unproven(String),
}

/// One journal row as the chain reads it.
struct Row {
    ordinal: i64,
    operation: String,
    aggregate: String,
    aggregate_id: String,
    state: Option<String>,
    mirrors: Option<String>,
}

fn pack(hasher: &mut Sha256, field: Option<&str>) {
    match field {
        None => hasher.update([0u8]),
        Some(text) => {
            hasher.update([1u8]);
            hasher.update((text.len() as u64).to_be_bytes());
            hasher.update(text.as_bytes());
        }
    }
}

/// The digest after one row.
fn step(previous: &str, row: &Row) -> String {
    let mut hasher = Sha256::new();
    hasher.update(previous.as_bytes());
    pack(&mut hasher, Some(&row.operation));
    pack(&mut hasher, Some(&row.aggregate));
    pack(&mut hasher, Some(&row.aggregate_id));
    pack(&mut hasher, row.state.as_deref());
    pack(&mut hasher, row.mirrors.as_deref());
    format!("{:x}", hasher.finalize())
}

/// Creates the table the seals live in, beside the journal. Idempotent.
///
/// # Errors
///
/// Returns an error if the role may not create the table.
pub async fn ensure_anchors<C: GenericClient>(client: &C) -> anyhow::Result<()> {
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_ledger_anchors (
                aggregate_table text        NOT NULL,
                through_sequence bigint     NOT NULL,
                head            text        NOT NULL,
                previous        text        NOT NULL,
                sealed_at       timestamptz NOT NULL DEFAULT now(),
                PRIMARY KEY (aggregate_table, through_sequence)
            )",
        )
        .await
        .context("creating hecks_ledger_anchors")
}

/// The seals a domain's journal carries, oldest first.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn anchors<C: GenericClient>(client: &C, domain: &str) -> anyhow::Result<Vec<Anchor>> {
    let rows = client
        .query(
            "SELECT through_sequence, head, previous FROM hecks_ledger_anchors \
             WHERE aggregate_table = $1 ORDER BY through_sequence",
            &[&journal_table(domain)],
        )
        .await
        .context("reading hecks_ledger_anchors")?;
    Ok(rows
        .iter()
        .map(|row| Anchor {
            through: row.get(0),
            head: row.get(1),
            previous: row.get(2),
        })
        .collect())
}

async fn page<C: GenericClient>(
    client: &C,
    journal: &str,
    after: i64,
    through: i64,
) -> anyhow::Result<Vec<Row>> {
    let rows = client
        .query(
            &format!(
                "SELECT ordinal, operation, aggregate, aggregate_id, state::text, mirrors::text \
                 FROM {} WHERE ordinal > $1 AND ordinal <= $2 ORDER BY ordinal LIMIT $3",
                quote_ident(journal)
            ),
            &[&after, &through, &PAGE],
        )
        .await
        .with_context(|| format!("reading {journal} after ordinal {after}"))?;
    Ok(rows
        .iter()
        .map(|row| Row {
            ordinal: row.get(0),
            operation: row.get(1),
            aggregate: row.get(2),
            aggregate_id: row.get(3),
            state: row.get(4),
            mirrors: row.get(5),
        })
        .collect())
}

/// The digest after every journal row in `(after, through]`, seeded by `seed`, and how many rows
/// that was.
async fn fold<C: GenericClient>(
    client: &C,
    journal: &str,
    seed: &str,
    after: i64,
    through: i64,
) -> anyhow::Result<(String, i64)> {
    let mut digest = seed.to_string();
    let mut cursor = after;
    let mut counted = 0_i64;
    loop {
        let rows = page(client, journal, cursor, through).await?;
        let Some(last) = rows.last() else {
            return Ok((digest, counted));
        };
        cursor = last.ordinal;
        counted += i64::try_from(rows.len()).unwrap_or(i64::MAX);
        digest = rows
            .iter()
            .fold(digest, |previous, row| step(&previous, row));
    }
}

/// The highest ordinal every writer has committed.
///
/// Writers take this advisory lock before they take an ordinal and hold it to their commit, so once
/// it is held no lower ordinal is still in flight. It is released at once: the rows read after it
/// are committed and immutable, and a seal never makes a write wait while it hashes.
async fn settled_end(client: &mut Client, domain: &str, journal: &str) -> anyhow::Result<i64> {
    let transaction = client.transaction().await?;
    transaction
        .execute(
            "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
            &[&domain],
        )
        .await
        .context("taking the domain's write lock")?;
    let row = transaction
        .query_one(
            &format!(
                "SELECT COALESCE(max(ordinal), 0) FROM {}",
                quote_ident(journal)
            ),
            &[],
        )
        .await
        .with_context(|| format!("reading the end of {journal}"))?;
    transaction.commit().await?;
    Ok(row.get(0))
}

/// Seals the domain's journal at its present end.
///
/// Returns the new seal, or `None` when nothing was appended since the last one. Sealing the same
/// end twice records one seal.
///
/// # Errors
///
/// Returns an error if the database refuses a statement. A seal builds on the head already
/// recorded and does not re-read the rows it covers; finding a rewrite there is [`verify`]'s job.
pub async fn seal(client: &mut Client, domain: &str) -> anyhow::Result<Option<Anchor>> {
    let journal = journal_table(domain);
    ensure_anchors(client).await?;
    let held = anchors(client, domain).await?;
    let (after, seed) = held.last().map_or_else(
        || (0, GENESIS.to_string()),
        |last| (last.through, last.head.clone()),
    );

    let end = settled_end(client, domain, &journal).await?;
    if end <= after {
        return Ok(None);
    }
    Ok(Some(extend(client, &journal, after, seed, end).await?))
}

/// Seals the domain's journal from inside a commit, once `every` or more rows lie past the last
/// seal.
///
/// For the transaction that just appended lineage rows: the caller holds the domain's write lock,
/// so the journal's end is settled and this takes no lock of its own. The seal is written on the
/// same connection, so it commits or rolls back with the rows it covers. Returns the seal taken,
/// or `None` while fewer than `every` rows are unsealed. An interval below one seals on every
/// commit.
///
/// # Errors
///
/// Returns an error if the database refuses a statement.
pub async fn seal_due<C: GenericClient>(
    client: &C,
    domain: &str,
    every: i64,
) -> anyhow::Result<Option<Anchor>> {
    let journal = journal_table(domain);
    ensure_anchors(client).await?;
    let held = anchors(client, domain).await?;
    let (after, seed) = held.last().map_or_else(
        || (0, GENESIS.to_string()),
        |last| (last.through, last.head.clone()),
    );
    let end = last_ordinal(client, domain).await?;
    if end - after < every.max(1) {
        return Ok(None);
    }
    Ok(Some(extend(client, &journal, after, seed, end).await?))
}

/// Folds the rows in `(after, end]` onto `seed` and records the result as the next seal.
async fn extend<C: GenericClient>(
    client: &C,
    journal: &str,
    after: i64,
    seed: String,
    end: i64,
) -> anyhow::Result<Anchor> {
    let (head, _) = fold(client, journal, &seed, after, end).await?;
    client
        .execute(
            "INSERT INTO hecks_ledger_anchors (aggregate_table, through_sequence, head, previous) \
             VALUES ($1, $2, $3, $4)",
            &[&journal, &end, &head, &seed],
        )
        .await
        .context("recording the seal")?;
    Ok(Anchor {
        through: end,
        head,
        previous: seed,
    })
}

/// Walks the chain from the first seal, comparing each with the journal and with the one before.
///
/// # Errors
///
/// Returns an error only when the database cannot be read; a chain that does not hold is a
/// [`Finding::Unproven`], not an error.
pub async fn verify<C: GenericClient>(client: &C, domain: &str) -> anyhow::Result<Finding> {
    let journal = journal_table(domain);
    ensure_anchors(client).await?;
    let held = anchors(client, domain).await?;
    if held.is_empty() {
        return Ok(Finding::Unproven(
            "nothing is sealed yet: the chain cannot be shown intact".to_string(),
        ));
    }

    let mut before = Anchor {
        through: 0,
        head: GENESIS.to_string(),
        previous: GENESIS.to_string(),
    };
    let mut entries = 0_i64;
    for anchor in &held {
        if anchor.previous != before.head {
            return Ok(Finding::Unproven(format!(
                "{journal}: the seal through {} does not follow the seal before it",
                anchor.through
            )));
        }
        let (recomputed, counted) = fold(
            client,
            &journal,
            &anchor.previous,
            before.through,
            anchor.through,
        )
        .await?;
        if recomputed != anchor.head {
            return Ok(Finding::Unproven(format!(
                "{journal}: the seal through {} does not match the journal",
                anchor.through
            )));
        }
        entries += counted;
        before = anchor.clone();
    }

    let end: i64 = client
        .query_one(
            &format!(
                "SELECT COALESCE(max(ordinal), 0) FROM {}",
                quote_ident(&journal)
            ),
            &[],
        )
        .await
        .with_context(|| format!("reading the end of {journal}"))?
        .get(0);
    Ok(Finding::Verified(Report {
        seals: held.len(),
        entries,
        unsealed: (end - before.through).max(0),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_postgres::NoTls;

    fn row(operation: &str, id: &str, state: Option<&str>) -> Row {
        Row {
            ordinal: 1,
            operation: operation.to_string(),
            aggregate: "order".to_string(),
            aggregate_id: id.to_string(),
            state: state.map(str::to_string),
            mirrors: None,
        }
    }

    #[test]
    fn a_digest_is_sixty_four_lowercase_hex_digits() {
        let digest = step(GENESIS, &row("save", "o1", Some("{\"a\": 1}")));
        assert_eq!(digest.len(), 64);
        assert!(digest
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
    }

    #[test]
    fn the_same_row_after_a_different_head_digests_differently() {
        let one = step(GENESIS, &row("save", "o1", None));
        let two = step(&one, &row("save", "o1", None));
        assert_ne!(one, two);
    }

    #[test]
    fn fields_that_split_differently_do_not_collide() {
        let joined = Row {
            aggregate: "ab".to_string(),
            aggregate_id: "c".to_string(),
            ..row("save", "c", None)
        };
        let split = Row {
            aggregate: "a".to_string(),
            aggregate_id: "bc".to_string(),
            ..row("save", "bc", None)
        };
        assert_ne!(step(GENESIS, &joined), step(GENESIS, &split));
    }

    #[test]
    fn an_absent_state_is_not_an_empty_one() {
        assert_ne!(
            step(GENESIS, &row("save", "o1", None)),
            step(GENESIS, &row("save", "o1", Some("")))
        );
    }

    /// A scratch database with a journal shaped like the lineage one, without its partitions.
    async fn scratch(name: &str) -> Client {
        let (admin, connection) =
            tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), NoTls)
                .await
                .expect("connect as the admin role");
        tokio::spawn(async move {
            let _ = connection.await;
        });
        admin
            .batch_execute(&format!("DROP DATABASE IF EXISTS {name}"))
            .await
            .expect("drop the scratch database");
        admin
            .batch_execute(&format!("CREATE DATABASE {name}"))
            .await
            .expect("create the scratch database");

        let (client, connection) = tokio_postgres::connect(&crate::test_pg::conninfo(name), NoTls)
            .await
            .expect("connect to the scratch database");
        tokio::spawn(async move {
            let _ = connection.await;
        });
        client
            .batch_execute(
                "CREATE TABLE hecks_journal_shop (
                    ordinal bigserial, era int NOT NULL DEFAULT 1, aggregate text NOT NULL,
                    aggregate_id text NOT NULL, operation text NOT NULL DEFAULT 'save',
                    state jsonb, mirrors jsonb)",
            )
            .await
            .expect("create the journal");
        client
    }

    async fn append(client: &Client, id: &str, state: &str) {
        client
            .execute(
                "INSERT INTO hecks_journal_shop (aggregate, aggregate_id, state) \
                 VALUES ('order', $1, $2::text::jsonb)",
                &[&id, &state],
            )
            .await
            .expect("append a journal row");
    }

    #[test]
    fn the_interval_defaults_and_zero_turns_commit_sealing_off() {
        assert_eq!(seal_every(None), Ok(Some(DEFAULT_SEAL_EVERY)));
        assert_eq!(seal_every(Some("")), Ok(Some(DEFAULT_SEAL_EVERY)));
        assert_eq!(seal_every(Some(" 250 ")), Ok(Some(250)));
        assert_eq!(seal_every(Some("0")), Ok(None));
        assert!(seal_every(Some("-1")).unwrap_err().contains(SEAL_EVERY_VAR));
        assert!(seal_every(Some("many")).unwrap_err().contains("many"));
    }

    #[tokio::test]
    async fn a_commit_seals_only_once_the_interval_of_rows_is_unsealed() {
        let client = scratch("rust_host_ledger_due").await;
        append(&client, "o1", "{\"n\": 1}").await;
        append(&client, "o2", "{\"n\": 2}").await;
        assert_eq!(seal_due(&client, "Shop", 3).await.expect("not yet"), None);
        append(&client, "o3", "{\"n\": 3}").await;
        let first = seal_due(&client, "Shop", 3)
            .await
            .expect("due")
            .expect("a seal");
        assert_eq!((first.through, first.previous.as_str()), (3, GENESIS));
        append(&client, "o4", "{\"n\": 4}").await;
        assert_eq!(seal_due(&client, "Shop", 3).await.expect("not yet"), None);

        let finding = verify(&client, "Shop").await.expect("verify");
        assert_eq!(
            finding,
            Finding::Verified(Report {
                seals: 1,
                entries: 3,
                unsealed: 1
            })
        );
    }

    #[tokio::test]
    async fn a_seal_taken_inside_a_transaction_leaves_with_the_rows_it_covered() {
        let mut client = scratch("rust_host_ledger_in_txn").await;
        append(&client, "o1", "{\"n\": 1}").await;
        ensure_anchors(&client).await.expect("the anchors table");
        let transaction = client.transaction().await.expect("begin");
        transaction
            .execute(
                "INSERT INTO hecks_journal_shop (aggregate, aggregate_id, state) \
                 VALUES ('order', 'o2', '{\"n\": 2}')",
                &[],
            )
            .await
            .expect("append inside the transaction");
        let sealed = seal_due(&transaction, "Shop", 2)
            .await
            .expect("due")
            .expect("a seal");
        assert_eq!(sealed.through, 2);
        transaction.rollback().await.expect("roll back");

        assert!(anchors(&client, "Shop").await.expect("anchors").is_empty());
        let finding = verify(&client, "Shop").await.expect("verify");
        assert!(
            matches!(finding, Finding::Unproven(reason) if reason.contains("nothing is sealed"))
        );
    }

    #[tokio::test]
    async fn sealing_an_empty_journal_records_nothing() {
        let mut client = scratch("rust_host_ledger_empty").await;
        assert_eq!(seal(&mut client, "Shop").await.expect("seal"), None);
    }

    #[tokio::test]
    async fn a_walk_with_nothing_sealed_is_unproven() {
        let client = scratch("rust_host_ledger_unsealed").await;
        append(&client, "o1", "{\"n\": 1}").await;
        let finding = verify(&client, "Shop").await.expect("verify");
        assert!(
            matches!(finding, Finding::Unproven(reason) if reason.contains("nothing is sealed"))
        );
    }

    #[tokio::test]
    async fn an_untouched_journal_walks_clean_and_counts_the_unsealed_tail() {
        let mut client = scratch("rust_host_ledger_clean").await;
        append(&client, "o1", "{\"n\": 1}").await;
        append(&client, "o2", "{\"n\": 2}").await;
        let first = seal(&mut client, "Shop")
            .await
            .expect("seal")
            .expect("a seal");
        assert_eq!(first.previous, GENESIS);
        append(&client, "o3", "{\"n\": 3}").await;
        seal(&mut client, "Shop").await.expect("seal again");
        append(&client, "o4", "{\"n\": 4}").await;

        let finding = verify(&client, "Shop").await.expect("verify");
        assert_eq!(
            finding,
            Finding::Verified(Report {
                seals: 2,
                entries: 3,
                unsealed: 1
            })
        );
    }

    #[tokio::test]
    async fn sealing_the_same_end_twice_records_one_seal() {
        let mut client = scratch("rust_host_ledger_twice").await;
        append(&client, "o1", "{\"n\": 1}").await;
        seal(&mut client, "Shop").await.expect("seal");
        assert_eq!(seal(&mut client, "Shop").await.expect("seal again"), None);
        assert_eq!(anchors(&client, "Shop").await.expect("anchors").len(), 1);
    }

    #[tokio::test]
    async fn a_later_seal_follows_the_head_before_it() {
        let mut client = scratch("rust_host_ledger_chain").await;
        append(&client, "o1", "{\"n\": 1}").await;
        let first = seal(&mut client, "Shop")
            .await
            .expect("seal")
            .expect("first");
        append(&client, "o2", "{\"n\": 2}").await;
        let second = seal(&mut client, "Shop")
            .await
            .expect("seal")
            .expect("second");
        assert_eq!(second.previous, first.head);
    }

    #[tokio::test]
    async fn a_rewritten_row_is_found() {
        let mut client = scratch("rust_host_ledger_rewritten").await;
        append(&client, "o1", "{\"n\": 1}").await;
        append(&client, "o2", "{\"n\": 2}").await;
        seal(&mut client, "Shop").await.expect("seal");
        client
            .execute(
                "UPDATE hecks_journal_shop SET state = '{\"n\": 99}' WHERE aggregate_id = 'o1'",
                &[],
            )
            .await
            .expect("rewrite a row");

        let finding = verify(&client, "Shop").await.expect("verify");
        assert!(matches!(finding, Finding::Unproven(reason) if reason.contains("does not match")));
    }

    #[tokio::test]
    async fn a_deleted_row_is_found() {
        let mut client = scratch("rust_host_ledger_deleted").await;
        append(&client, "o1", "{\"n\": 1}").await;
        append(&client, "o2", "{\"n\": 2}").await;
        seal(&mut client, "Shop").await.expect("seal");
        client
            .execute(
                "DELETE FROM hecks_journal_shop WHERE aggregate_id = 'o1'",
                &[],
            )
            .await
            .expect("delete a row");

        let finding = verify(&client, "Shop").await.expect("verify");
        assert!(matches!(finding, Finding::Unproven(reason) if reason.contains("does not match")));
    }

    #[tokio::test]
    async fn a_seal_that_does_not_follow_its_predecessor_is_found() {
        let mut client = scratch("rust_host_ledger_link").await;
        append(&client, "o1", "{\"n\": 1}").await;
        seal(&mut client, "Shop").await.expect("seal");
        append(&client, "o2", "{\"n\": 2}").await;
        seal(&mut client, "Shop").await.expect("seal again");
        client
            .execute(
                "UPDATE hecks_ledger_anchors SET previous = $1 WHERE through_sequence = 2",
                &[&"f".repeat(64)],
            )
            .await
            .expect("break the link");

        let finding = verify(&client, "Shop").await.expect("verify");
        assert!(matches!(finding, Finding::Unproven(reason) if reason.contains("does not follow")));
    }
}
