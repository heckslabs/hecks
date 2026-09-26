// **The lambda entry point** — provided.al2023 custom runtime, no
// container (per explicit direction: PackageType Zip, not Image). A
// Lambda event is either a command (`{"verb": "...", "args": {...}}`,
// the same shape a single entry of the kernel's own `{"steps": [...]}`
// array already has — no new request shape invented for that path) or
// a read (`{"read": true}` — no verb at all, checked first so it can
// never be confused with a command that simply omitted one). Both
// response shapes are the kernel's own `{"instances","events",
// "refusals"}` output, unchanged, so anything that already knows how
// to read bin/rust_conformance's JSON (a human, a test, future
// tooling) reads this Lambda's response either way.
//
// Postgres and wasmtime are both held only here and in the two modules
// this file composes (journal, wasm_runner) — dispatch.rs is the only
// place that sees both at once. The `.wasm` module itself never learns
// either exists.

mod api;
mod approval;
mod auth;
mod checkout;
mod dispatch;
mod expr_json;
mod field_hints;
mod ir;
mod journal;
mod lambda_client;
mod mint;
mod payments;
mod presentation;
mod presentation_write;
mod reference_transform;
mod reference_validate;
mod resend;
mod secrets;
mod server;
mod storage_shape;
mod ui_schema;
mod wasm_runner;
mod web;

use lambda_runtime::{service_fn, Error, LambdaEvent};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;

#[tokio::main]
async fn main() -> Result<(), Error> {
    // HECKS_SERVE_MODE=1 — read here, at the very top, before any of the
    // boot work below runs: `serve_mode`'s own value never changes what
    // that boot work does (server.rs's own header — every step from here
    // down through the era-minting sequence is shared, unchanged, by
    // both modes), only which of the two loops at the bottom of this
    // function ever receives the finished boot state. Set by
    // `fargate.rb`'s own generated container `Environment` — unset (or
    // anything but "1") keeps this binary running as the Lambda
    // custom-runtime process it always has, which is what every
    // existing deployed Lambda still expects.
    let serve_mode = std::env::var("HECKS_SERVE_MODE").as_deref() == Ok("1");

    // HECKS_SESSION_COOKIE names the account cookie. A name that could not
    // be written into a Set-Cookie header refuses the boot here, rather
    // than quietly falling back to the default at request time.
    auth::resolve_account_cookie(std::env::var("HECKS_SESSION_COOKIE").ok().as_deref())?;

    // DB_SECRET_ARN — bin/project_deploy's own default now (template.yaml's
    // Environment.Variables comment has the full story): the password
    // itself is fetched from Secrets Manager here, at cold start, over
    // the AWS SDK, rather than trusted from a CloudFormation dynamic
    // reference already resolved into this function's own
    // Environment.Variables — which is readable in plaintext by any
    // principal with read-only access to the account
    // (lambda:GetFunctionConfiguration), not the secret-at-rest
    // protection its own name suggests. DB_HOST/DB_NAME travel as plain
    // (non-secret) Environment.Variables alongside it.
    //
    // Falls back to DATABASE_URL directly when DB_SECRET_ARN is absent —
    // the one legitimate case being a human hand-debugging over an SSM
    // tunnel with DATABASE_URL set manually (project_deploy's own
    // ExcludeCharacters comment already anticipates exactly this).
    //
    // One fetcher, built eagerly and reused below for GOOGLE_OAUTH_SECRET_ID/
    // SESSION_SECRET_ARN too -- a real deploy always sets DB_SECRET_ARN
    // (bin/project_deploy's own default), so this is the common path in
    // practice; building it even in the DATABASE_URL-fallback debugging
    // case costs one unused HTTP client, not worth branching around.
    let secret_fetcher = secrets::AwsSecretFetcher::from_env().await;
    let database_url = match std::env::var("DB_SECRET_ARN") {
        Ok(secret_arn) => {
            let db_host = std::env::var("DB_HOST").map_err(|_| "DB_HOST is required when DB_SECRET_ARN is set")?;
            let db_name = std::env::var("DB_NAME").map_err(|_| "DB_NAME is required when DB_SECRET_ARN is set")?;
            let secret_json = secret_fetcher
                .fetch_secret_string(&secret_arn)
                .await
                .map_err(|e| format!("fetching DB_SECRET_ARN from Secrets Manager: {e:#}"))?;
            let password = secrets::extract_field(&secret_json, "password")?;
            // Composed to match the format template.yaml's retired
            // `{{resolve:secretsmanager:...}}` DATABASE_URL Sub produced:
            // literal, unescaped, no percent-encoding. parse_database_url
            // below never percent-decodes the password segment either way.
            format!("postgres://postgres:{password}@{db_host}:5432/{db_name}")
        }
        Err(_) => std::env::var("DATABASE_URL")
            .map_err(|_| "either DB_SECRET_ARN (+ DB_HOST/DB_NAME) or DATABASE_URL is required")?,
    };

    // GOOGLE_OAUTH_SECRET_ID/SESSION_SECRET_ARN — the same
    // {{resolve:secretsmanager:...}}-into-Environment.Variables exposure
    // DB_SECRET_ARN above replaced, applied to auth.rs's own
    // GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET and web.rs's own
    // SESSION_SECRET. Fetched here, once, then `unsafe { set_var }`'d
    // into the same env keys auth.rs/web.rs already read via
    // `std::env::var(...)` — neither file changes at all; from their
    // own point of view this is indistinguishable from a human having
    // exported the real value directly. Safety: this runs before
    // `tokio::spawn` below or any request is ever dispatched — nothing
    // else in this process reads or writes the environment concurrently
    // with these two calls.
    if let Ok(oauth_secret_id) = std::env::var("GOOGLE_OAUTH_SECRET_ID") {
        let secret_json = secret_fetcher
            .fetch_secret_string(&oauth_secret_id)
            .await
            .map_err(|e| format!("fetching GOOGLE_OAUTH_SECRET_ID from Secrets Manager: {e:#}"))?;
        let client_id = secrets::extract_field(&secret_json, "client_id")?;
        let client_secret = secrets::extract_field(&secret_json, "client_secret")?;
        unsafe {
            std::env::set_var("GOOGLE_CLIENT_ID", client_id);
            std::env::set_var("GOOGLE_CLIENT_SECRET", client_secret);
        }
    }
    if let Ok(session_secret_arn) = std::env::var("SESSION_SECRET_ARN") {
        let secret_json = secret_fetcher
            .fetch_secret_string(&session_secret_arn)
            .await
            .map_err(|e| format!("fetching SESSION_SECRET_ARN from Secrets Manager: {e:#}"))?;
        let session_secret = secrets::extract_field(&secret_json, "session_secret")?;
        unsafe {
            std::env::set_var("SESSION_SECRET", session_secret);
        }
    }
    // RESEND_SECRET_ID (`{"api_key":"re_..."}`) — fetched and set as
    // RESEND_API_KEY the same way, but a failed fetch only logs: sending
    // mail is one optional route, and a missing or unreadable secret must
    // not stop the host serving everything else. Without the key the send
    // routes answer 503 (resend.rs). Same safety argument as above: nothing
    // else touches the environment yet.
    if let Ok(resend_secret_id) = std::env::var("RESEND_SECRET_ID") {
        let fetched = secret_fetcher.fetch_secret_string(&resend_secret_id).await.map_err(|e| format!("{e:#}"));
        match fetched.and_then(|json| secrets::extract_field(&json, "api_key")) {
            Ok(api_key) => unsafe { std::env::set_var("RESEND_API_KEY", api_key) },
            Err(e) => eprintln!("RESEND_SECRET_ID could not be read, so email sending stays off: {e}"),
        }
    }
    let wasm_path = PathBuf::from(
        std::env::var("HECKS_WASM_PATH").unwrap_or_else(|_| "banking.wasm".to_string()),
    );

    // Read before the Postgres connection opens — `SET search_path`
    // below has to run before `journal::ensure_schema`/anything else
    // touches the connection, or those calls resolve unqualified names
    // against Postgres's own default search_path instead of this
    // domain's. `HECKS_SCHEMA` is optional, same as Ruby's own
    // `settings[:schema]` (postgres.rb) — a domain with its own
    // dedicated instance (today's default, not the storehouse) sets
    // nothing here and keeps Postgres's ordinary default search_path,
    // exactly today's behavior, unchanged.
    let domain = std::env::var("HECKS_DOMAIN").map_err(|_| "HECKS_DOMAIN is required")?;
    let schema = std::env::var("HECKS_SCHEMA").ok().filter(|s| !s.is_empty());

    // RDS Postgres refuses a plain NoTls connection by default (real,
    // live error: "no pg_hba.conf entry ... no encryption") -- and
    // needs AWS's own RDS ca specifically, not a generic public bundle
    // (see Cargo.toml's own comment on both points).
    let mut roots = rustls::RootCertStore::empty();
    for cert in rustls_pemfile::certs(&mut include_bytes!("../rds-ca-bundle.pem").as_slice()) {
        roots.add(cert.map_err(|e| format!("parsing rds-ca-bundle.pem: {e}"))?)?;
    }
    let tls_config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let tls = tokio_postgres_rustls::MakeRustlsConnect::new(tls_config);
    // Not tokio_postgres::connect(&database_url, tls) -- that parses
    // DATABASE_URL as a strict URI, where `?`/`#` are reserved
    // delimiter characters (query-string/fragment starts). template.yaml's
    // own DATABASE_URL is composed by CloudFormation's `!Sub` straight
    // from RDS/Aurora's auto-generated ManageMasterUserPassword secret
    // -- which AWS excludes `/`, `"`, `@`, and whitespace from, but not
    // `?`/`#`/other URI-reserved characters, and CloudFormation has no
    // way to percent-encode inline. A real, live "db error" (an
    // authentication failure, the password silently truncated at the
    // first `?`) caught this: `EiP$wT3S9Gi?#rIAjSDii*>GHKPX` parsed as
    // a URI query string starting at `?`, leaving only `EiP$wT3S9Gi` as
    // the "password" tokio_postgres actually sent. `parse_database_url`
    // below never percent-decodes or URI-parses the password segment at
    // all -- splits on the last `@` (safe: AWS's own exclusion list
    // guarantees no literal `@` in the password) and hands the
    // remaining bytes to `Config::password` completely literally.
    let mut config = parse_database_url(&database_url)?;
    // RDS requires TLS (this crate's rds-ca-bundle.pem). Local Postgres
    // is reached over loopback — rustls with the RDS CA cannot verify a
    // Homebrew/Postgres.app cert, so localhost is NoTls. Mechanical from
    // the host in DATABASE_URL, not a deploy-time env flag.
    let local_postgres = database_url_is_local(&config);
    if !local_postgres {
        config.ssl_mode(tokio_postgres::config::SslMode::Require);
    }
    // Two connect paths, spawned separately: NoTlsStream and
    // RustlsStream cannot unify in one `if`. Local is loopback (Homebrew
    // Postgres.app); everything else is RDS and needs the bundle above.
    let client = if local_postgres {
        let (client, connection) = config
            .connect(tokio_postgres::NoTls)
            .await
            .map_err(|e| format!("connecting to Postgres via DATABASE_URL: {e:?}"))?;
        tokio::spawn(async move {
            if let Err(e) = connection.await {
                eprintln!("postgres connection error: {e:#}");
            }
        });
        client
    } else {
        let (client, connection) = config
            .connect(tls)
            .await
            .map_err(|e| format!("connecting to Postgres via DATABASE_URL: {e:?}"))?;
        tokio::spawn(async move {
            if let Err(e) = connection.await {
                eprintln!("postgres connection error: {e:#}");
            }
        });
        client
    };

    // **Shared-instance isolation** — same reasoning as postgres_era.rb's own
    // `connect_for`: every unqualified table/view reference this binary
    // ever issues (hecks_lambda_journal, hecks_lambda_snapshot,
    // hecks_eras, the era-partitioned lineage tables in journal.rs)
    // resolves through search_path, so this one set is what makes a
    // shared instance's per-domain schemas transparent to the rest of
    // this binary — no other call site needs to change.
    //
    // CREATE SCHEMA IF NOT EXISTS FIRST — the exact fix postgres_era.rb's
    // own `connect_for` already carries (its own comment: "found live
    // provisioning tenant_isolation_spec.rb's own multi-schema fixture
    // by hand"), missing here until a Shared-mode domain's Lambda
    // actually booted against a schema neither Banking nor Pizzas ever
    // needed created this way (their own schemas were already created
    // by `make mint-era`'s Ruby-side tunnel boot before their Lambda's
    // own first real invocation ever ran) — found live deploying
    // lifeadelics, the first Shared-mode domain whose Lambda genuinely
    // raced a still-nonexistent schema: `SET search_path` to a schema
    // that doesn't exist yet succeeds in Postgres (search_path accepts
    // any name), so the first real failure only surfaced one step
    // later, `ensure_schema`'s own `CREATE TABLE ... IF NOT EXISTS`
    // refusing with "no schema has been selected to create in" — a
    // genuinely confusing message pointing nowhere near the real cause.
    // Idempotent, same as Ruby's: a schema that already exists is the
    // ordinary case on every boot after the first, not news.
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

    let ir = ir::ir().ok_or("HECKS_IR_PATH is not set or unreadable — this binary needs its own domain's ir.json sidecar")?;
    ir::refuse_unsupported_persistence_adapters(ir)?;
    let my_hash = storage_shape::mint_hash(ir);
    let my_label = storage_shape::mint_label(ir);

    let mut aggregates: Vec<mint::Aggregate> = ir::lineage_capable_aggregates(ir)
        .into_iter()
        .map(|(qualified, storage_name)| {
            let name = qualified.rsplit("::").next().unwrap_or(&qualified).to_string();
            mint::Aggregate { name, storage_name }
        })
        .collect();
    // A chapter that `provides "membership"` names who may sign in
    // (Person, Member, …). That aggregate is often vendored, so it is
    // not in this domain's own lineage.capable_aggregates — still mint
    // its head under HECKS_DOMAIN so rust/host Google-auth can read it.
    if let Some(membership) = ir::membership_provider(ir) {
        let name = membership.aggregate.rsplit("::").next().unwrap_or(&membership.aggregate).to_string();
        let storage_name = journal::snake(&name);
        if !aggregates.iter().any(|a| a.storage_name == storage_name) {
            aggregates.push(mint::Aggregate { name, storage_name });
        }
    }

    // ADR 0034 — the era-partitioned lineage subsystem (hecks_eras, the
    // mint/hold/audit sequence below, per-aggregate head-snapshot
    // journaling) is only provisioned when something actually needs it:
    // at least one aggregate this domain's own ir.json marks lineage-
    // capable, or Google auth is configured at all (`GOOGLE_CLIENT_ID`
    // set) — `auth.rs`'s own Member sessions always require the lineage
    // subsystem present, by design (ADR 0034's own Decision), regardless
    // of what any other aggregate in this domain binds to. A domain with
    // neither never touches `hecks_eras`, never mints, never partitions —
    // structurally absent from this boot's own call graph, the same
    // "conditional on real capability, not a no-op" shape ADR 0031
    // already established Ruby-side for `Runtime::BootGates`.
    let needs_lineage = !aggregates.is_empty() || std::env::var("GOOGLE_CLIENT_ID").is_ok();

    let era: Option<i32> = if needs_lineage {
        // `hecks_eras`/`hecks_approvals`/the six `hecks_tr_*` functions —
        // idempotent, gated by `provisioner?` on the connecting role's own
        // ownership (mint.rs's own header), so calling this every boot is
        // exactly as cheap and safe as `journal::ensure_schema` above.
        // Must run before the very first `journal::held_eras` call below —
        // on a truly fresh Postgres instance (no domain has ever minted
        // anything yet), `hecks_eras` itself doesn't exist until this runs;
        // found live, by `mint_harness` (ADR-0030-in-progress step 8's own
        // differential harness) hitting exactly that on a scratch database
        // no prior test had ever exercised this boot path against.
        mint::ensure_base(&client, &domain).await.map_err(|e| format!("provisioning hecks_eras for {domain}: {e:#}"))?;

        // **The boot gate** — no longer a bare `HECKS_ERA` ordinal comparison.
        // This binary computes its own shape hash (`storage_shape`, over
        // `ir::ir()` — the same `ir.json` sidecar this crate already loads
        // generically) and decides for itself: does a held era already
        // name this exact shape (boot at it, whichever ordinal — RLS
        // refuses a write if it turns out to be superseded, the same
        // guarantee `journal::lineage_tests::
        // a_stale_era_write_is_refused_by_postgres_rls_not_this_crate`
        // already proves), is this domain brand new (mint era 1 itself,
        // `mint::hold_first`), or has it drifted (find the one translation
        // edge leaving the latest held era, mint the next one itself,
        // `mint::mint_era` — refusing by name toward `bin/scaffold_
        // translation` if none covers it, or `bin/translation_audit
        // --approve` if one does but needs a human's sample review first,
        // `approval::check`). `HECKS_ERA` is gone entirely — an operator
        // no longer declares what era to run as; this binary decides.
        let held = journal::held_eras(&client, &domain).await.map_err(|e| format!("checking hecks_eras for {domain}: {e:#}"))?;

        // The actual decision is a pure function (`mint::decide_boot_action`,
        // directly unit-tested) — everything below is just carrying out
        // whichever of its four outcomes came back, the only part that
        // genuinely needs `client`/`ir`.
        let ordinal: i32 = match mint::decide_boot_action(&held, &my_label) {
            // Adopting an era someone else minted still has to provision
            // what this binary is about to write into. Ruby does this on
            // every boot, for every repository, "regardless of era" —
            // this crate only ever did it while minting, so a host that
            // matched an existing era's label wrote its first mutation
            // into a head-snapshot table nobody had created. Found live
            // on embryonautfoundersapp, whose era 2 was minted by Ruby
            // under the pre-ADR-0059 unqualified names: every
            // domain-qualified snapshot in that database stopped at era
            // 1, and no write of any kind could succeed.
            mint::BootDecision::UseExisting { ordinal } => {
                mint::adopt_head_snapshots(&client, &domain, &aggregates, ordinal)
                    .await
                    .map_err(|e| format!("adopting era {ordinal} of {domain}: {e:#}"))?;
                ordinal
            }
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
                // carry more than one). `approval::check` needs the raw
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
                // ordering: before anything is minted, over the live
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
                mint::mint_era(&client, &domain, ordinal, &my_hash, &my_label, held_text, &aggregates, &chain, None, &mint::lifecycle_defaults(ir))
                    .await
                    .map_err(|e| format!("minting era {ordinal} of {domain}: {e:#}"))?;
                ordinal
            }
        };
        Some(ordinal)
    } else {
        None
    };

    // The mirrored set is the IR's own capable list, by qualified name
    // — never "everything this kernel can mutate". A domain that binds
    // everything to plain `Postgres` mirrors nothing, and its writes go
    // to this crate's own journal alone, which is what `dispatch::read`
    // replays anyway.
    let mirrored = ir::mirrored_aggregates(ir);
    let lineage_config = Arc::new(journal::LineageConfig { domain, era, mirrored: Some(mirrored) });

    // Mutex, not a bare Arc<Client> -- dispatch::handle needs
    // Client::transaction (which takes &mut Client) to hold the
    // advisory lock across the whole rehydrate-then-append sequence.
    // See dispatch.rs's own comment for what that guards against.
    let client = Arc::new(Mutex::new(client));
    let wasm_path = Arc::new(wasm_path);
    // One `AwsLambdaInvoker` for this process's whole lifetime, same
    // reasoning as `client`/`wasm_path` above — `aws_config::load_defaults`
    // resolves credentials/region once at boot (an IAM role's own
    // environment, inside a deployed Lambda), not per invocation.
    // `lambda_client.rs`'s own header has the full story on what this is
    // for: delivering a cross-domain policy reaction the compiled `.wasm`
    // module could only match, never dispatch (no network inside that
    // sandbox, structurally).
    let invoker = Arc::new(lambda_client::AwsLambdaInvoker::from_env().await);

    // `role` -- optional, mirroring `args`: `Adapters::Lambda::Client#
    // dispatch` (Ruby) only puts this key on the wire when a caller is
    // actually bound (`payload["role"] = role if role`), so an absent
    // key means exactly what it always has -- no caller asserted a
    // role, and `dispatch::handle`'s own `check_role` stays on its
    // unchecked path, unchanged. This is the fix for a real wiring gap,
    // not new behavior: `check_role` (kernel/repository.rs) and
    // `cli.rs`'s own `step.get("role")` were both already correct and
    // already exercised (the cross-Lambda-policy-dispatch work reused
    // this same mechanism successfully) -- but nothing on this side of
    // the wire ever read an incoming event's `"role"` field at all, so
    // every real Lambda invocation reached `check_role` with
    // `caller_role: None` regardless of what Ruby's client actually
    // sent, and role-based authorization was silently unreachable in
    // production. `server::dispatch_body` (shared with the Fargate
    // server path below) is where this is actually read now.
    if serve_mode {
        let state = server::ServerState { client, wasm_path, lineage_config, invoker };
        return server::serve(state).await;
    }

    lambda_runtime::run(service_fn(move |event: LambdaEvent<serde_json::Value>| {
        let client = Arc::clone(&client);
        let wasm_path = Arc::clone(&wasm_path);
        let lineage_config = Arc::clone(&lineage_config);
        let invoker = Arc::clone(&invoker);
        async move {
            let (body, _context) = event.into_parts();
            server::dispatch_body(body, &client, &wasm_path, &lineage_config, invoker.as_ref()).await
        }
    }))
    .await
}

// Parses `postgres://user:password@host:port/dbname` without treating
// it as a URI — see main()'s own comment on why: an RDS/Aurora
// auto-generated password can contain `?`/`#`/other URI-reserved
// characters CloudFormation's `!Sub` never percent-encodes, and a real
// URI parser (tokio_postgres::connect's own string-form path)
// misinterprets them as delimiters, silently truncating the password.
// Splits on the last `@` (never inside the password -- AWS's own
// managed-secret generation excludes `@` unconditionally, confirmed:
// https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-rds-database-instance.html#aws-properties-rds-database-instance-return-values
// documents `/`, `"`, `@`, and whitespace as always excluded) and the
// first `:` in the user:password segment (the user, "postgres", never
// contains one) -- the password segment itself is never percent-decoded
// or re-parsed after that, handed to `Config::password` completely
// literally.
fn parse_database_url(url: &str) -> Result<tokio_postgres::Config, String> {
    let rest = url
        .strip_prefix("postgres://")
        .or_else(|| url.strip_prefix("postgresql://"))
        .ok_or_else(|| format!("DATABASE_URL doesn't start with postgres:// or postgresql://"))?;

    let (authority, db_and_query) = rest
        .split_once('/')
        .ok_or_else(|| "DATABASE_URL has no '/' separating host from database name".to_string())?;
    let dbname = db_and_query.split(['?', '#']).next().unwrap_or(db_and_query);

    let (credentials, host_and_port) = match authority.rsplit_once('@') {
        Some((credentials, host_and_port)) => (Some(credentials), host_and_port),
        None => (None, authority),
    };
    let (host, port) = match host_and_port.rsplit_once(':') {
        Some((host, port)) => {
            let port: u16 = port
                .parse()
                .map_err(|e| format!("DATABASE_URL's port {port:?} isn't a valid number: {e}"))?;
            (host, port)
        }
        None => (host_and_port, 5432),
    };

    let mut config = tokio_postgres::Config::new();
    config.host(host).port(port).dbname(dbname);
    if let Some(credentials) = credentials {
        match credentials.split_once(':') {
            Some((user, password)) => {
                config.user(user).password(password);
            }
            None => {
                config.user(credentials);
            }
        }
    }
    Ok(config)
}

fn database_url_is_local(config: &tokio_postgres::Config) -> bool {
    use tokio_postgres::config::Host;
    config.get_hosts().iter().any(|host| match host {
        Host::Tcp(name) => name == "localhost" || name == "127.0.0.1" || name == "::1",
        _ => false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_password_with_uri_reserved_characters() {
        let config = parse_database_url(
            "postgres://postgres:T3st$Pa?#ss*>Word@db.example.com:5432/pizzas",
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

    #[test]
    fn parses_a_local_url_with_no_user_or_port() {
        let config = parse_database_url("postgres://localhost/app_development")
            .expect("should parse a peer-auth local URL");
        assert_eq!(config.get_dbname(), Some("app_development"));
        assert_eq!(config.get_ports(), &[5432]);
        assert!(database_url_is_local(&config));
    }
}
