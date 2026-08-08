// THE REHYDRATE-AND-REPLAY JOURNAL — flat, non-era-aware, and
// deliberately domain-agnostic: one table for the WHOLE domain's
// command history, not one per aggregate. Rust has no era/lineage
// concept at all (a known, already-documented gap from ADR 0011), and
// rust/host has no type information about aggregates/commands (that
// knowledge lives only inside the compiled `.wasm` module, which this
// crate treats as opaque) — so filtering "which prior commands matter
// for this one" isn't something rust/host can safely do on its own.
// Replaying the FULL log on every invocation is the simplest correct
// answer for a company-internal tool with modest total event volume;
// see docs/decisions/0018-rehydrate-replay-lambda-host.md for the full
// tradeoff.
//
// Determinism is what makes this safe to persist selectively: every
// prior journal row was, by construction, a command that succeeded the
// first time it was dispatched — replaying the exact same steps against
// the exact same (empty-start) kernel must produce the exact same
// result again. So the ONLY step in a full replay that can legitimately
// end up in `refusals` is the newest one, appended last. That's the
// entire correctness argument `append_if_accepted` below leans on.

use tokio_postgres::Client;

pub async fn ensure_schema(client: &Client) -> anyhow::Result<()> {
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS hecks_lambda_journal (
                ordinal     BIGSERIAL PRIMARY KEY,
                verb        TEXT NOT NULL,
                args        JSONB NOT NULL,
                recorded_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )",
        )
        .await?;
    Ok(())
}

/// Every command ever successfully dispatched, in order, as `{"verb",
/// "args"}` objects — the exact shape a `{"steps": [...]}` entry needs.
pub async fn load_steps(client: &Client) -> anyhow::Result<Vec<serde_json::Value>> {
    let rows = client
        .query(
            "SELECT verb, args FROM hecks_lambda_journal ORDER BY ordinal",
            &[],
        )
        .await?;

    Ok(rows
        .iter()
        .map(|row| {
            let verb: String = row.get(0);
            let args: serde_json::Value = row.get(1);
            serde_json::json!({ "verb": verb, "args": args })
        })
        .collect())
}

pub async fn append(client: &Client, verb: &str, args: &serde_json::Value) -> anyhow::Result<()> {
    client
        .execute(
            "INSERT INTO hecks_lambda_journal (verb, args) VALUES ($1, $2)",
            &[&verb, &args],
        )
        .await?;
    Ok(())
}
