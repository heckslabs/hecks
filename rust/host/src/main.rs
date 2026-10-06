//! Lambda custom-runtime entry point (or a long-lived server under
//! HECKS_SERVE_MODE=1): boots Postgres/wasm state, then dispatches events.

mod api;
mod approval;
mod auth;
mod checkout;
mod dispatch;
mod expr_json;
mod field_hints;
#[cfg(test)]
mod fuzz_support;
#[cfg(test)]
#[path = "boundary_fuzz/expr_json.rs"]
mod expr_json_fuzz;
mod ir;
mod journal;
mod lambda_client;
mod log;
mod mint;
mod needs;
mod payments;
mod presentation;
mod presentation_write;
mod query_step;
mod rate_limit;
mod reference_transform;
mod reference_validate;
mod resend;
mod secrets;
mod server;
mod storage_shape;
#[cfg(test)]
mod test_pg;
mod ui_schema;
mod wasm_runner;
mod web;

use lambda_runtime::{service_fn, Error, LambdaEvent};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;

#[tokio::main]
async fn main() -> Result<(), Error> {
    // HECKS_SERVE_MODE=1 switches the boot into the long-lived server
    // loop below instead of the Lambda custom-runtime loop; every step
    // from here through the era-minting sequence is shared, unchanged,
    // by both modes.
    let boot_started = std::time::Instant::now();
    let serve_mode = std::env::var("HECKS_SERVE_MODE").as_deref() == Ok("1");

    // HECKS_SESSION_COOKIE names the account cookie; refuse the boot
    // here if it can't be written into a Set-Cookie header, rather
    // than falling back silently at request time.
    auth::resolve_account_cookie(std::env::var("HECKS_SESSION_COOKIE").ok().as_deref())?;

    // DB_SECRET_ARN: the password is fetched from Secrets Manager here,
    // at cold start, rather than trusted from a plaintext
    // Environment.Variables value, which any principal with
    // lambda:GetFunctionConfiguration could read regardless of the
    // secret-at-rest protection its name suggests. Falls back to
    // DATABASE_URL directly when DB_SECRET_ARN is absent (manual
    // debugging over an SSM tunnel).
    //
    // The fetcher built here is reused below for GOOGLE_OAUTH_SECRET_ID
    // and SESSION_SECRET_ARN too.
    let secret_fetcher = secrets::AwsSecretFetcher::from_env().await;
    let database_url = match std::env::var("DB_SECRET_ARN") {
        Ok(secret_arn) => {
            let db_host = std::env::var("DB_HOST").map_err(|_| "DB_HOST is required when DB_SECRET_ARN is set")?;
            let db_name = std::env::var("DB_NAME").map_err(|_| "DB_NAME is required when DB_SECRET_ARN is set")?;
            let secret_json = secret_fetcher
                .fetch_secret_string(&secret_arn)
                .await
                .map_err(|e| format!("fetching DB_SECRET_ARN from Secrets Manager: {e:#}"))?;
            // The user and port come from the secret too (a client sharing an instance logs in as
            // its own role); the password goes in literal, since parse_database_url below never
            // percent-decodes it.
            secrets::database_url(&secret_json, &db_host, &db_name)?
        }
        Err(_) => std::env::var("DATABASE_URL")
            .map_err(|_| "either DB_SECRET_ARN (+ DB_HOST/DB_NAME) or DATABASE_URL is required")?,
    };

    // GOOGLE_OAUTH_SECRET_ID/SESSION_SECRET_ARN: the same
    // Secrets-Manager-at-cold-start approach as DB_SECRET_ARN above,
    // applied to auth.rs's GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET and
    // web.rs's SESSION_SECRET.
    //
    // Safety: this runs before any request is dispatched, so nothing
    // else reads or writes the environment concurrently with these
    // `set_var` calls.
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
    // RESEND_SECRET_ID: fetched the same way, but a failed fetch only
    // logs -- mail is optional, and a missing secret must not stop the
    // host from serving everything else (resend.rs answers 503 without
    // a key).
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

    // Must run before the Postgres connection opens -- `SET search_path`
    // below has to run before `journal::ensure_schema` or anything else
    // touches the connection, or unqualified names resolve against
    // Postgres's default search_path instead of this domain's.
    // HECKS_SCHEMA is optional.
    let domain = std::env::var("HECKS_DOMAIN").map_err(|_| "HECKS_DOMAIN is required")?;
    let schema = std::env::var("HECKS_SCHEMA").ok().filter(|s| !s.is_empty());
    // Checkout on AWS keeps the business's payment keys in a named Secrets
    // Manager secret; refuse before touching the database when none is named.
    payments::check_boot(web::checkout_enabled(std::env::var("HECKS_CHECKOUT_DOMAIN").ok().as_deref(), &domain))?;

    // RDS refuses a plain NoTls connection by default and needs AWS's
    // own RDS CA specifically, not a generic public bundle (see
    // Cargo.toml).
    let mut roots = rustls::RootCertStore::empty();
    for cert in rustls_pemfile::certs(&mut include_bytes!("../rds-ca-bundle.pem").as_slice()) {
        roots.add(cert.map_err(|e| format!("parsing rds-ca-bundle.pem: {e}"))?)?;
    }
    let tls_config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let tls = tokio_postgres_rustls::MakeRustlsConnect::new(tls_config);
    // Not tokio_postgres::connect(url, tls) -- that treats DATABASE_URL
    // as a strict URI, and RDS-generated passwords can contain
    // URI-reserved `?`/`#` that CloudFormation never percent-encodes.
    let mut config = parse_database_url(&database_url)?;
    // RDS requires TLS (rds-ca-bundle.pem); local Postgres over loopback
    // can't be verified against the RDS CA, so localhost uses NoTls.
    let local_postgres = database_url_is_local(&config);
    if !local_postgres {
        config.ssl_mode(tokio_postgres::config::SslMode::Require);
    }
    // NoTlsStream and RustlsStream can't unify in one branch, so the
    // two paths are spawned separately.
    let connect_phase = log::phase_with("db_connect", serde_json::json!({ "tls": !local_postgres }));
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

    connect_phase.end();

    // Every unqualified table/view reference this binary issues
    // resolves through search_path, so this is what makes a shared
    // instance's per-domain schemas transparent to the rest of the
    // binary.
    //
    // CREATE SCHEMA before SET search_path: setting search_path to a
    // schema that doesn't exist yet succeeds in Postgres, so a missing
    // schema only surfaces later as a confusing "no schema has been
    // selected to create in" error from `ensure_schema`. Idempotent: an
    // existing schema is the ordinary case on every boot after the first.
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

    let phase = log::phase("ensure_schema");
    journal::ensure_schema(&client)
        .await
        .map_err(|e| format!("provisioning hecks_lambda_journal: {e:#}"))?;
    phase.end();

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
    // A chapter that `provides "membership"` names who may sign in; that
    // aggregate can be vendored, so it may be missing from this domain's
    // lineage-capable list. Mint its head anyway for Google-auth to read.
    if let Some(membership) = ir::membership_provider(ir) {
        let name = membership.aggregate.rsplit("::").next().unwrap_or(&membership.aggregate).to_string();
        let storage_name = journal::snake(&name);
        if !aggregates.iter().any(|a| a.storage_name == storage_name) {
            aggregates.push(mint::Aggregate { name, storage_name });
        }
    }

    // The era-partitioned lineage subsystem is provisioned only when
    // something needs it: a lineage-capable aggregate, or Google auth
    // configured (ADR 0034 requires it for Member sessions either way).
    let needs_lineage = !aggregates.is_empty() || std::env::var("GOOGLE_CLIENT_ID").is_ok();

    let era: Option<i32> = if needs_lineage {
        // Idempotent (gated by `provisioner?`); must run before the
        // first `journal::held_eras` call, since `hecks_eras` doesn't
        // exist yet on a truly fresh Postgres instance.
        let phase = log::phase("ensure_base");
        mint::ensure_base(&client, &domain).await.map_err(|e| format!("provisioning hecks_eras for {domain}: {e:#}"))?;
        phase.end();

        // Compares this binary's own shape hash (`storage_shape`, over
        // `ir::ir()`) against held eras to decide the boot action: boot
        // at a matching era, mint era 1 if the domain is new, or mint
        // the next era if it has drifted -- refusing toward
        // `hecks scaffold_translation` (no edge covers it) or
        // `hecks audit_translation --approve` (needs review) otherwise.
        let era_phase = log::phase("era_resolve");
        let held = journal::held_eras(&client, &domain).await.map_err(|e| format!("checking hecks_eras for {domain}: {e:#}"))?;

        // The decision itself is a pure, unit-tested function
        // (`mint::decide_boot_action`); everything below just carries
        // out whichever of its four outcomes came back.
        let decision = mint::decide_boot_action(&held, &my_label);
        era_phase.end_with(serde_json::json!({ "held_eras": held.len(), "decision": decision.name() }));
        let ordinal: i32 = match decision {
            // Adopting an existing era still provisions what this binary
            // is about to write into, the same as minting does --
            // skipping it would let a matched-era host write into
            // head-snapshot tables that were never created.
            mint::BootDecision::UseExisting { ordinal } => {
                let phase = log::phase_with("adopt_head_snapshots", serde_json::json!({ "era": ordinal }));
                mint::adopt_head_snapshots(&client, &domain, &aggregates, ordinal)
                    .await
                    .map_err(|e| format!("adopting era {ordinal} of {domain}: {e:#}"))?;
                phase.end();
                ordinal
            }
            mint::BootDecision::HoldFirst => {
                let source_text =
                    ir.get("source_text").and_then(serde_json::Value::as_str).ok_or("ir.json is missing source_text — regenerate with hecks project_rust")?;
                let phase = log::phase_with("hold_first", serde_json::json!({ "era": 1 }));
                mint::hold_first(&client, &domain, source_text, ir, &aggregates, None).await.map_err(|e| format!("minting era 1 of {domain}: {e:#}"))?;
                phase.end();
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
                         ({my_label}) no translation edge covers -- {e} -- run hecks scaffold_translation, review it \
                         with hecks audit_translation, then redeploy",
                    )
                })?;

                // Checks every edge in the chain with a compute/rekey
                // rule, not just the newest -- a chain can carry more
                // than one, matched against the raw ir.json edge
                // (digest-relevant shape) by the same from/to pair.
                let raw_edges = ir.get("translations").and_then(serde_json::Value::as_array).cloned().unwrap_or_default();
                let committed_approvals = approval::committed(ir);
                let approval_phase = log::phase_with("approval_check", serde_json::json!({ "edges": chain.len(), "committed": committed_approvals.len() }));
                for edge in &chain {
                    let Some(raw_edge) = raw_edges.iter().find(|candidate| {
                        candidate.get("domain").and_then(serde_json::Value::as_str) == Some(domain.as_str())
                            && candidate.get("from").and_then(serde_json::Value::as_str) == Some(edge.from.as_str())
                            && candidate.get("to").and_then(serde_json::Value::as_str) == Some(edge.to.as_str())
                    }) else {
                        return Err(format!("cannot boot: {domain}'s edge {} -> {} vanished between parsing and approval-checking it", edge.from, edge.to).into());
                    };
                    approval::check(&client, &domain, raw_edge, ordinal, &committed_approvals).await.map_err(|e| format!("{e:#}"))?;
                }
                approval_phase.end();

                // Runs before anything is minted, over the live compiled
                // chain (plain SELECTs, never a persisted matview), so a
                // refusal leaves no half-born era.
                let watermarks: std::collections::HashMap<i32, Option<i64>> = held.iter().map(|held_era| (held_era.ordinal, held_era.watermark)).collect();
                let audit_phase = log::phase_with("audit_before_mint", serde_json::json!({ "era": ordinal, "edges": chain.len() }));
                mint::audit_before_mint(&client, &domain, ir, &aggregates, ordinal, &chain, &raw_edges, &watermarks)
                    .await
                    .map_err(|e| format!("{e:#}"))?;
                audit_phase.end();

                let held_text = ir.get("source_text").and_then(serde_json::Value::as_str).ok_or("ir.json is missing source_text — regenerate with hecks project_rust")?;
                let mint_phase = log::phase_with("mint_era", serde_json::json!({ "era": ordinal, "edges": chain.len() }));
                mint::mint_era(&client, &domain, ordinal, &my_hash, &my_label, held_text, &aggregates, &chain, None, &mint::lifecycle_defaults(ir))
                    .await
                    .map_err(|e| format!("minting era {ordinal} of {domain}: {e:#}"))?;
                mint_phase.end();
                ordinal
            }
        };
        Some(ordinal)
    } else {
        None
    };

    // The mirrored set is the IR's own capable list, by qualified name
    // -- never "everything this kernel can mutate". A domain that binds
    // everything to plain `Postgres` mirrors nothing.
    let mirrored = ir::mirrored_aggregates(ir);
    let lineage_config = Arc::new(journal::LineageConfig { domain, era, mirrored: Some(mirrored) });

    // Mutex, not a bare Arc<Client> -- dispatch::handle needs
    // Client::transaction (&mut Client) to hold the advisory lock
    // across the rehydrate-then-append sequence (see dispatch.rs).
    let client = Arc::new(Mutex::new(client));
    let wasm_path = Arc::new(wasm_path);
    // One invoker for this process's lifetime -- credentials/region
    // resolve once at boot, not per invocation. See lambda_client.rs:
    // the compiled `.wasm` module can't dispatch this itself (no
    // network inside that sandbox).
    let invoker = Arc::new(lambda_client::AwsLambdaInvoker::from_env().await);

    // `role` is optional, mirroring `args`: an absent key means no
    // caller asserted a role, and `dispatch::handle`'s `check_role`
    // stays on its unchecked path. Read by `server::dispatch_body` below.
    if serve_mode {
        log::info(
            "boot",
            serde_json::json!({ "mode": "serve", "domain": &lineage_config.domain, "era": &my_label, "boot_ms": boot_started.elapsed().as_millis() as u64 }),
        );
        let version = server::version_body(&my_label, &my_hash, std::env::var("HECKS_BUILD").ok().as_deref());
        let limits = Arc::new(rate_limit::RateLimits::from_env());
        let state = server::ServerState { client, wasm_path, lineage_config, invoker, limits };
        return server::serve(state, version).await;
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

// Parses `postgres://user:password@host:port/db` without treating it
// as a URI -- an RDS/Aurora auto-generated password can contain
// `?`/`#`, which a strict URI parser would treat as delimiters.
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
