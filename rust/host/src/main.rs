// THE LAMBDA ENTRY POINT — provided.al2023 custom runtime, no
// container (per explicit direction: PackageType Zip, not Image). A
// Lambda event is EITHER a command (`{"verb": "...", "args": {...}}`,
// the same shape a single entry of the kernel's own `{"steps": [...]}`
// array already has — no new request shape invented for that path) OR
// a read (`{"read": true}` — no verb at all, checked first so it can
// never be confused with a command that simply omitted one). Both
// response shapes are the kernel's own `{"instances","events",
// "refusals"}` output, unchanged, so anything that already knows how
// to read bin/rust_conformance's JSON (a human, a test, future
// tooling) reads this Lambda's response either way.
//
// Postgres and wasmtime are BOTH held only here and in the two modules
// this file composes (journal, wasm_runner) — dispatch.rs is the only
// place that sees both at once. The `.wasm` module itself never learns
// either exists.

mod approval;
mod auth;
mod checkout;
mod dispatch;
mod field_hints;
mod ir;
mod journal;
mod lambda_client;
mod mint;
mod reference_transform;
mod reference_validate;
mod storage_shape;
mod wasm_runner;
mod web;

use lambda_runtime::{service_fn, Error, LambdaEvent};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;

#[tokio::main]
async fn main() -> Result<(), Error> {
    let database_url = std::env::var("DATABASE_URL").map_err(|_| "DATABASE_URL is required")?;
    let wasm_path = PathBuf::from(
        std::env::var("HECKS_WASM_PATH").unwrap_or_else(|_| "banking.wasm".to_string()),
    );

    // Read BEFORE the Postgres connection opens — `SET search_path`
    // below has to run before `journal::ensure_schema`/anything else
    // touches the connection, or those calls resolve unqualified names
    // against Postgres's own default search_path instead of this
    // domain's. `HECKS_SCHEMA` is OPTIONAL, same as Ruby's own
    // `settings[:schema]` (postgres.rb) — a domain with its own
    // dedicated instance (today's default, not the storehouse) sets
    // nothing here and keeps Postgres's ordinary default search_path,
    // exactly today's behavior, unchanged.
    let domain = std::env::var("HECKS_DOMAIN").map_err(|_| "HECKS_DOMAIN is required")?;
    let schema = std::env::var("HECKS_SCHEMA").ok().filter(|s| !s.is_empty());

    // RDS Postgres refuses a plain NoTls connection by default (real,
    // live error: "no pg_hba.conf entry ... no encryption") -- and
    // needs AWS's own RDS CA specifically, not a generic public bundle
    // (see Cargo.toml's own comment on both points).
    let mut roots = rustls::RootCertStore::empty();
    for cert in rustls_pemfile::certs(&mut include_bytes!("../rds-ca-bundle.pem").as_slice()) {
        roots.add(cert.map_err(|e| format!("parsing rds-ca-bundle.pem: {e}"))?)?;
    }
    let tls_config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let tls = tokio_postgres_rustls::MakeRustlsConnect::new(tls_config);
    // NOT tokio_postgres::connect(&database_url, tls) -- that parses
    // DATABASE_URL as a strict URI, where `?`/`#` are RESERVED
    // delimiter characters (query-string/fragment starts). template.yaml's
    // own DATABASE_URL is composed by CloudFormation's `!Sub` straight
    // from RDS/Aurora's auto-generated ManageMasterUserPassword secret
    // -- which AWS excludes `/`, `"`, `@`, and whitespace from, but NOT
    // `?`/`#`/other URI-reserved characters, and CloudFormation has no
    // way to percent-encode inline. A real, live "db error" (an
    // authentication failure, the password silently truncated at the
    // first `?`) caught this: `EiP$wT3S9Gi?#rIAjSDii*>GHKPX` parsed as
    // a URI query string starting at `?`, leaving only `EiP$wT3S9Gi` as
    // the "password" tokio_postgres actually sent. `parse_database_url`
    // below never percent-decodes or URI-parses the password segment at
    // all -- splits on the LAST `@` (safe: AWS's own exclusion list
    // guarantees no literal `@` in the password) and hands the
    // remaining bytes to `Config::password` completely literally.
    let mut config = parse_database_url(&database_url)?;
    // EXPLICIT, not Config::new()'s own default -- confirmed live that
    // leaving this implicit produced an opaque, undiagnosable "db
    // error" with no further detail even from {:?} (Debug), while a
    // manual psql/openssl s_client reproduction against the SAME
    // credentials/host over an SSM tunnel succeeded fine on both
    // `sslmode=require` and `sslmode=disable` -- ruling out the
    // credentials, the TLS cert chain (rds-ca-bundle.pem verifies
    // clean), and the security groups (Aurora accepted the tunneled
    // connection). Require, not Prefer, matches this crate's own
    // stated intent ("RDS Postgres refuses a plain NoTls connection by
    // default") explicitly rather than leaving tokio_postgres to infer
    // it.
    config.ssl_mode(tokio_postgres::config::SslMode::Require);
    // Named, operator-facing context on failure -- mirrors postgres.rb's
    // own WiringError wrapping (`cannot bind Postgres at ... for ...`).
    // DATABASE_URL itself is never interpolated into either message
    // (it carries credentials); the underlying error text is the only
    // detail that travels. `{e:?}` (Debug, not Display) -- confirmed
    // live that even `{e:#}` (alternate Display) collapsed to the bare
    // label "db error" with nothing further for this specific failure,
    // unlike the anyhow-wrapped errors elsewhere in this crate that
    // `{:#}` genuinely does expand; Debug is the fallback that's
    // guaranteed to show whatever tokio_postgres::Error actually holds.
    let (client, connection) = config
        .connect(tls)
        .await
        .map_err(|e| format!("connecting to Postgres via DATABASE_URL: {e:?}"))?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("postgres connection error: {e:#}");
        }
    });

    // SHARED-INSTANCE ISOLATION — same reasoning as postgres_era.rb's own
    // `connect_for`: every unqualified table/view reference this binary
    // ever issues (hecks_lambda_journal, hecks_lambda_snapshot,
    // hecks_eras, the era-partitioned lineage tables in journal.rs)
    // resolves through search_path, so this one SET is what makes a
    // shared instance's per-domain schemas transparent to the rest of
    // this binary — no other call site needs to change.
    //
    // CREATE SCHEMA IF NOT EXISTS FIRST — the exact fix postgres_era.rb's
    // own `connect_for` already carries (its own comment: "found live
    // provisioning tenant_isolation_spec.rb's own multi-schema fixture
    // by hand"), missing here until a Shared-mode domain's Lambda
    // actually booted against a schema neither Banking nor Pizzas ever
    // needed created THIS way (their own schemas were already created
    // by `make mint-era`'s Ruby-side tunnel boot before their Lambda's
    // own first real invocation ever ran) — found live deploying
    // lifeadelics, the first Shared-mode domain whose Lambda genuinely
    // raced a still-nonexistent schema: `SET search_path` to a schema
    // that doesn't exist yet succeeds in Postgres (search_path accepts
    // any name), so the FIRST real failure only surfaced one step
    // later, `ensure_schema`'s own `CREATE TABLE ... IF NOT EXISTS`
    // refusing with "no schema has been selected to create in" — a
    // genuinely confusing message pointing nowhere near the real cause.
    // Idempotent, same as Ruby's: a schema that already exists is the
    // ORDINARY case on every boot after the first, not news.
    if let Some(schema) = &schema {
        client
            .batch_execute(&format!("CREATE SCHEMA IF NOT EXISTS {}", journal::quote_ident(schema)))
            .await
            .map_err(|e| format!("creating schema {schema:?}: {e:#}"))?;
        client
            .batch_execute(&format!("SET search_path TO {}", journal::quote_ident(schema)))
            .await
            .map_err(|e| format!("setting search_path to {schema:?}: {e:#}"))?;
    }

    journal::ensure_schema(&client)
        .await
        .map_err(|e| format!("provisioning hecks_lambda_journal: {e:#}"))?;

    // `hecks_eras`/`hecks_approvals`/the six `hecks_tr_*` functions —
    // idempotent, gated by `provisioner?` on the connecting role's own
    // ownership (mint.rs's own header), so calling this every boot is
    // exactly as cheap and safe as `journal::ensure_schema` above.
    // MUST run before the very first `journal::held_eras` call below —
    // on a truly fresh Postgres instance (no domain has ever minted
    // anything yet), `hecks_eras` itself doesn't exist until this runs;
    // found live, by `mint_harness` (ADR-0030-in-progress step 8's own
    // differential harness) hitting exactly that on a scratch database
    // no prior test had ever exercised this boot path against.
    mint::ensure_base(&client, &domain).await.map_err(|e| format!("provisioning hecks_eras for {domain}: {e:#}"))?;

    // THE BOOT GATE — no longer a bare `HECKS_ERA` ordinal comparison.
    // This binary computes ITS OWN shape hash (`storage_shape`, over
    // `ir::ir()` — the same `ir.json` sidecar this crate already loads
    // generically) and decides for itself: does a held era already
    // name this exact shape (boot at it, whichever ordinal — RLS
    // refuses a write if it turns out to be superseded, the same
    // guarantee `journal::lineage_tests::
    // a_stale_era_write_is_refused_by_postgres_rls_not_this_crate`
    // already proves), is this domain brand new (mint era 1 itself,
    // `mint::hold_first`), or has it drifted (find the ONE translation
    // edge leaving the latest held era, mint the next one itself,
    // `mint::mint_era` — refusing by name toward `bin/scaffold_
    // translation` if none covers it, or `bin/translation_audit
    // --approve` if one does but needs a human's sample review first,
    // `approval::check`). `HECKS_ERA` is gone entirely — an operator
    // no longer declares what era to run as; this binary decides.
    let ir = ir::ir().ok_or("HECKS_IR_PATH is not set or unreadable — this binary needs its own domain's ir.json sidecar")?;
    let my_hash = storage_shape::mint_hash(ir);
    let my_label = storage_shape::mint_label(ir);

    let aggregates: Vec<mint::Aggregate> = ir::lineage_capable_aggregates(ir)
        .into_iter()
        .map(|(qualified, storage_name)| {
            let name = qualified.rsplit("::").next().unwrap_or(&qualified).to_string();
            mint::Aggregate { name, storage_name }
        })
        .collect();

    let held = journal::held_eras(&client, &domain).await.map_err(|e| format!("checking hecks_eras for {domain}: {e:#}"))?;

    // The actual decision is a pure function (`mint::decide_boot_action`,
    // directly unit-tested) — everything below is just carrying out
    // whichever of its four outcomes came back, the only part that
    // genuinely needs `client`/`ir`.
    let era: i32 = match mint::decide_boot_action(&held, &my_label) {
        mint::BootDecision::UseExisting { ordinal } => ordinal,
        mint::BootDecision::HoldFirst => {
            let source_text =
                ir.get("source_text").and_then(serde_json::Value::as_str).ok_or("ir.json is missing source_text — regenerate with bin/project_rust")?;
            mint::hold_first(&client, &domain, source_text, ir, &aggregates, None).await.map_err(|e| format!("minting era 1 of {domain}: {e:#}"))?;
            1
        }
        mint::BootDecision::LatestUnnamed { ordinal } => {
            return Err(format!(
                "cannot boot: {domain}'s latest held era (ordinal {ordinal}) has no name yet -- this crate can't \
                 name it itself (no bluebook parser, ADR 0012's own boundary) -- boot Ruby once against this \
                 database to name it (Runtime::EraCheck's own lazy-naming path), then redeploy",
            )
            .into());
        }
        mint::BootDecision::Mint { ordinal, from_ordinal, from_label } => {
            let mut labels: Vec<String> = held.iter().map(|held_era| held_era.label.clone().unwrap_or_default()).collect();
            labels.push(my_label.clone());
            let edges = mint::parse_edges(ir, &domain);
            let chain = mint::edge_chain(&edges, &labels).map_err(|e| {
                format!(
                    "cannot boot: {domain} has drifted from era {from_ordinal} ({from_label}) to a shape \
                     ({my_label}) no translation edge covers -- {e} -- run bin/scaffold_translation, review it \
                     with bin/translation_audit, then redeploy",
                )
            })?;

            // The approval gate — every edge in the chain that carries a
            // compute/rekey rule, not just the newest link (a chain built
            // from a domain that skipped several boots in a row could
            // carry more than one). `approval::check` needs the RAW
            // ir.json Value for each edge (the digest-relevant shape,
            // never `mint::Edge`'s own already-compiled-SQL-bearing
            // struct), found by the same from/to pair `edge_chain` just
            // matched.
            let raw_edges = ir.get("translations").and_then(serde_json::Value::as_array).cloned().unwrap_or_default();
            for edge in &chain {
                let Some(raw_edge) = raw_edges.iter().find(|candidate| {
                    candidate.get("domain").and_then(serde_json::Value::as_str) == Some(domain.as_str())
                        && candidate.get("from").and_then(serde_json::Value::as_str) == Some(edge.from.as_str())
                        && candidate.get("to").and_then(serde_json::Value::as_str) == Some(edge.to.as_str())
                }) else {
                    return Err(format!("cannot boot: {domain}'s edge {} -> {} vanished between parsing and approval-checking it", edge.from, edge.to).into());
                };
                approval::check(&client, &domain, raw_edge, ordinal).await.map_err(|e| format!("{e:#}"))?;
            }

            // Layer 2 of the live audit — CoverageCheck#audit!'s own
            // ordering: BEFORE anything is minted, over the live
            // compiled chain (plain SELECTs, never a persisted matview),
            // so a refusal leaves no half-born era. `watermarks` uses
            // `held` exactly as fetched above — era `ordinal` genuinely
            // has no row yet, matching what Ruby's own audit sees at
            // this same pre-mint moment.
            let watermarks: std::collections::HashMap<i32, Option<i64>> = held.iter().map(|held_era| (held_era.ordinal, held_era.watermark)).collect();
            mint::audit_before_mint(&client, &domain, ir, &aggregates, ordinal, &chain, &raw_edges, &watermarks)
                .await
                .map_err(|e| format!("{e:#}"))?;

            let held_text = ir.get("source_text").and_then(serde_json::Value::as_str).ok_or("ir.json is missing source_text — regenerate with bin/project_rust")?;
            mint::mint_era(&client, &domain, ordinal, &my_hash, &my_label, held_text, &aggregates, &chain, None)
                .await
                .map_err(|e| format!("minting era {ordinal} of {domain}: {e:#}"))?;
            ordinal
        }
    };

    let lineage_config = Arc::new(journal::LineageConfig { domain, era });

    // Mutex, not a bare Arc<Client> -- dispatch::handle needs
    // Client::transaction (which takes &mut Client) to hold the
    // advisory lock across the whole rehydrate-then-append sequence.
    // See dispatch.rs's own comment for what that guards against.
    let client = Arc::new(Mutex::new(client));
    let wasm_path = Arc::new(wasm_path);
    // ONE `AwsLambdaInvoker` for this process's whole lifetime, same
    // reasoning as `client`/`wasm_path` above — `aws_config::load_defaults`
    // resolves credentials/region once at boot (an IAM role's own
    // environment, inside a deployed Lambda), not per invocation.
    // `lambda_client.rs`'s own header has the full story on what this is
    // for: delivering a cross-domain policy reaction the compiled `.wasm`
    // module could only MATCH, never dispatch (no network inside that
    // sandbox, structurally).
    let invoker = Arc::new(lambda_client::AwsLambdaInvoker::from_env().await);

    lambda_runtime::run(service_fn(move |event: LambdaEvent<serde_json::Value>| {
        let client = Arc::clone(&client);
        let wasm_path = Arc::clone(&wasm_path);
        let lineage_config = Arc::clone(&lineage_config);
        let invoker = Arc::clone(&invoker);
        async move {
            let (body, _context) = event.into_parts();

            // A Function-URL HTTP event (requestContext.http/rawPath
            // present) -- the public web UI, served in-process, no
            // second Lambda. `None` for anything else (the internal
            // {"read"}/{"verb"} shapes below), so this changes nothing
            // for a domain with no HECKS_IR_PATH configured.
            if let Some(response) = web::render(&body, &client, &wasm_path, &lineage_config, invoker.as_ref()).await {
                return Ok::<serde_json::Value, Error>(response);
            }

            if body.get("read").and_then(|v| v.as_bool()) == Some(true) {
                let result = dispatch::read(&client, &wasm_path).await?;
                return Ok::<serde_json::Value, Error>(result);
            }

            let verb = body
                .get("verb")
                .and_then(|v| v.as_str())
                .ok_or("event missing \"verb\"")?
                .to_string();
            // `"role"` -- OPTIONAL, mirroring `args` immediately above:
            // `Adapters::Lambda::Client#dispatch` (Ruby) only puts this
            // key on the wire when a caller is actually bound
            // (`payload["role"] = role if role`), so an absent key here
            // means exactly what it always has -- no caller asserted a
            // role, and `dispatch::handle`'s own `check_role` stays on
            // its unchecked path, unchanged. THIS is the fix for a real
            // wiring gap, not new behavior: `check_role`
            // (kernel/repository.rs) and `cli.rs`'s own
            // `step.get("role")` were both already correct and already
            // exercised (the cross-Lambda-policy-dispatch work reused
            // this same mechanism successfully) -- but nothing on this
            // side of the wire ever read an incoming event's `"role"`
            // field at all, so every real Lambda invocation reached
            // `check_role` with `caller_role: None` regardless of what
            // Ruby's client actually sent, and role-based authorization
            // was silently unreachable in production.
            let role = body
                .get("role")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());

            let outcome = if let Some(to) = body.get("to").cloned() {
                if body.get("args").is_some() {
                    return Err::<serde_json::Value, Error>("cannot combine to/with with legacy args".into());
                }
                let facts = body.get("with").cloned().unwrap_or_else(|| serde_json::json!({}));
                dispatch::handle_routed(
                    &client,
                    &wasm_path,
                    &verb,
                    to,
                    facts,
                    role.as_deref(),
                    &lineage_config,
                    invoker.as_ref(),
                )
                .await?
            } else if let Some(facts) = body.get("with").cloned() {
                if body.get("args").is_some() {
                    return Err::<serde_json::Value, Error>(
                        "cannot combine \"with\" with legacy args".into(),
                    );
                }
                dispatch::handle_facts(
                    &client,
                    &wasm_path,
                    &verb,
                    facts,
                    role.as_deref(),
                    &lineage_config,
                    invoker.as_ref(),
                )
                .await?
            } else {
                let args = body.get("args").cloned().unwrap_or_else(|| serde_json::json!({}));
                dispatch::handle(
                    &client,
                    &wasm_path,
                    &verb,
                    args,
                    role.as_deref(),
                    &lineage_config,
                    invoker.as_ref(),
                )
                .await?
            };
            Ok::<serde_json::Value, Error>(outcome.result)
        }
    }))
    .await
}

// Parses `postgres://user:password@host:port/dbname` WITHOUT treating
// it as a URI — see main()'s own comment on why: an RDS/Aurora
// auto-generated password can contain `?`/`#`/other URI-reserved
// characters CloudFormation's `!Sub` never percent-encodes, and a real
// URI parser (tokio_postgres::connect's own string-form path)
// misinterprets them as delimiters, silently truncating the password.
// Splits on the LAST `@` (never inside the password -- AWS's own
// managed-secret generation excludes `@` unconditionally, confirmed:
// https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-rds-database-instance.html#aws-properties-rds-database-instance-return-values
// documents `/`, `"`, `@`, and whitespace as always excluded) and the
// FIRST `:` in the user:password segment (the user, "postgres", never
// contains one) -- the password segment itself is never percent-decoded
// or re-parsed after that, handed to `Config::password` completely
// literally.
fn parse_database_url(url: &str) -> Result<tokio_postgres::Config, String> {
    let rest = url
        .strip_prefix("postgres://")
        .or_else(|| url.strip_prefix("postgresql://"))
        .ok_or_else(|| format!("DATABASE_URL doesn't start with postgres:// or postgresql://"))?;

    let (credentials, host_part) = rest
        .rsplit_once('@')
        .ok_or_else(|| "DATABASE_URL has no '@' separating credentials from host".to_string())?;
    let (user, password) = credentials
        .split_once(':')
        .ok_or_else(|| "DATABASE_URL's credentials have no ':' separating user from password".to_string())?;

    let (host_and_port, dbname) = host_part
        .split_once('/')
        .ok_or_else(|| "DATABASE_URL has no '/' separating host from database name".to_string())?;
    let (host, port) = host_and_port
        .rsplit_once(':')
        .ok_or_else(|| "DATABASE_URL's host has no ':' separating host from port".to_string())?;
    let port: u16 = port
        .parse()
        .map_err(|e| format!("DATABASE_URL's port {port:?} isn't a valid number: {e}"))?;

    let mut config = tokio_postgres::Config::new();
    config
        .host(host)
        .port(port)
        .user(user)
        .password(password)
        .dbname(dbname);
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_password_with_uri_reserved_characters() {
        let config = parse_database_url(
            "postgres://postgres:EiP$wT3S9Gi?#rIAjSDii*>GHKPX@hecks-pizzas-pizzasdbcluster-pfblqfmbmpf2.cluster-cmvsoy8c6td2.us-east-1.rds.amazonaws.com:5432/pizzas",
        )
        .expect("should parse despite ?/# in the password");
        assert_eq!(config.get_hosts().len(), 1);
        assert_eq!(config.get_ports(), &[5432]);
        assert_eq!(config.get_user(), Some("postgres"));
        assert_eq!(config.get_dbname(), Some("pizzas"));
    }

    #[test]
    fn parses_a_plain_password_too() {
        let config = parse_database_url("postgres://postgres:plainpassword@localhost:5432/pizzas")
            .expect("should parse a password with no special characters");
        assert_eq!(config.get_user(), Some("postgres"));
        assert_eq!(config.get_dbname(), Some("pizzas"));
    }
}
