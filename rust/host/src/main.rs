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

mod auth;
mod dispatch;
mod field_hints;
mod journal;
mod lambda_client;
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

    // SHARED-INSTANCE ISOLATION — same reasoning as postgres.rb's own
    // `SET search_path` (postgres.rb's `connect_for`): every unqualified
    // table/view reference this binary ever issues (hecks_lambda_journal,
    // hecks_lambda_snapshot, hecks_eras, the era-partitioned lineage
    // tables in journal.rs) resolves through search_path, so this one
    // SET is what makes a shared instance's per-domain schemas
    // transparent to the rest of this binary — no other call site needs
    // to change.
    if let Some(schema) = &schema {
        client
            .batch_execute(&format!("SET search_path TO {}", journal::quote_ident(schema)))
            .await
            .map_err(|e| format!("setting search_path to {schema:?}: {e:#}"))?;
    }

    journal::ensure_schema(&client)
        .await
        .map_err(|e| format!("provisioning hecks_lambda_journal: {e:#}"))?;

    // i32, matching Postgres `int` -- hecks_eras.ordinal and every
    // journal's own `era` column are `int` (int4) in Ruby's real DDL
    // (era_store.rb/provisioning.rb), not bigint; tokio_postgres
    // requires the Rust and Postgres types to match exactly, not just
    // be numerically compatible.
    let era: i32 = std::env::var("HECKS_ERA")
        .map_err(|_| "HECKS_ERA is required")?
        .parse()
        .map_err(|e| format!("HECKS_ERA must be an integer era ordinal: {e}"))?;

    // THE BOOT GATE -- refuses to start rather than write into tables
    // that may not exist, OR against a shape Ruby's own lineage RLS
    // fence no longer recognizes as current. rust/host never provisions
    // hecks_eras, the journal partition, or the head-snapshot tables
    // itself; that's Ruby's LineageManager alone (mint_era!/hold_first!).
    // Two distinct refusals, not one merged "bad era" message, because
    // an operator needs to know which fix applies: mint the domain (if
    // it's never been minted at all), or redeploy with the era mint_era!
    // already advanced to (if this checkout is simply stale) -- see
    // journal::current_era's own header for why a bare existence check
    // used to let the second case through silently.
    match journal::current_era(&client, &domain)
        .await
        .map_err(|e| format!("checking hecks_eras for {domain}: {e:#}"))?
    {
        None => {
            return Err(format!(
                "cannot boot: {domain} holds no era at all in hecks_eras -- \
                 this domain must already be minted by Ruby's own LineageManager \
                 (hold_first!) before rust/host can write into it"
            )
            .into());
        }
        Some(current) if current != era => {
            return Err(format!(
                "cannot boot: {domain} is configured for era {era}, but its current \
                 era is {current} -- this checkout is stale (superseded by a later \
                 mint_era!) and must be redeployed with HECKS_ERA={current}"
            )
            .into());
        }
        Some(_) => {}
    }
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
            let args = body
                .get("args")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));
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

            let outcome = dispatch::handle(&client, &wasm_path, &verb, args, role.as_deref(), &lineage_config, invoker.as_ref()).await?;
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
            "postgres://postgres:EiP$wT3S9Gi?#rIAjSDii*>GHKPX@hecksagain-pizzas-pizzasdbcluster-pfblqfmbmpf2.cluster-cmvsoy8c6td2.us-east-1.rds.amazonaws.com:5432/pizzas",
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
