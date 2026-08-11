// A DIRECT PORT of `Adapters::Lambda::Client` (lib/hecksagain/adapters/
// driven/lambda/client.rb) — read that file's own header first; this is
// the same thin, single-purpose wrapper (one Lambda invoke, one JSON
// round trip, the same "hecksagain-<domain>" function-name convention)
// for the ONE call site orchestrate.rs's own header names: a policy whose
// `across:` target domain isn't the one THIS process's own compiled
// `.wasm` module holds. That module runs inside wasmtime's sandbox
// (rust/host/Cargo.toml's own header, main.rs's own header) — no network,
// structurally — so it can only MATCH a cross-domain policy and hand back
// a `PendingCrossDomainReaction` (kernel::cli's "cross_domain_reactions"
// JSON output); this module is what actually DELIVERS it, from the one
// layer in this whole project with real AWS SDK access.
//
// FUNCTION NAME IS COMPUTED FROM A DECLARED STRING, not a path/basename —
// unlike `Adapters::Lambda::Client`'s own constructor, which resolves ITS
// OWN domain name from `ENV["DOMAIN_NAME"] || File.basename(registry.
// root)` specifically because `root` is always `/var/task` inside a
// deployed Lambda (that class's own comment: "a real, live
// AccessDeniedException on 'hecksagain-task' caught this"). This module
// has no equivalent guess to make: a cross-domain policy's target domain
// is baked into the generated `CrossDomainPolicyRule` table at codegen
// time, straight from its own `across "X"` declaration
// (rust/project/reactions.rb's `emit_cross_domain_policy_table`) — never
// derived from a path or working directory, so the whole bug CLASS Ruby's
// comment documents structurally cannot recur here.
//
// THE TRAIT BOUNDARY — `LambdaInvoker` — exists for exactly the reason
// `Adapters::Lambda::Client` itself is already a thin wrapper around one
// `Aws::Lambda::Client#invoke` call: everything this module can actually
// PROVE without live AWS infrastructure (the function name computed
// correctly, the payload shaped correctly, a domain-level refusal
// recognized correctly and swallowed the same way a same-domain policy
// reaction already is, a hard invoke fault propagated rather than
// swallowed) is provable against ANY implementer of this trait — this
// file's own `tests` module exercises exactly that, against a
// hand-written mock, with no real `aws_sdk_lambda::Client` or AWS
// credentials involved at all. `AwsLambdaInvoker`, below, is the ONE
// piece of this file that cannot be exercised here: it is real AWS SDK
// glue, structurally unverifiable without a second real domain's Lambda
// actually deployed and invocable. Its own doc comment says so plainly.

use serde_json::Value;

/// One Lambda invoke's raw outcome — `Adapters::Lambda::Client#invoke`'s
/// own two-part answer (`response.function_error`, `response.payload.
/// read`, parsed as JSON), carried across the trait boundary instead of
/// an `aws_sdk_lambda`-specific response type so a mock never needs to
/// construct one.
pub struct InvokeOutcome {
    pub body: Value,
    pub function_error: bool,
}

/// The seam a mock stands in for. `#[async_trait]`, not a native `async
/// fn` in a trait — `dispatch::handle` is reached from `web.rs`/`auth.rs`
/// through a long, already-deep call chain (`route` -> `command_route` ->
/// `submit`, `auth_route` -> `grant_access`, ...) that threads `&Mutex
/// <Client>`/`&Path`/`&LineageConfig` the same plain-reference way
/// already; making EVERY function in that chain generic over `L:
/// LambdaInvoker` just to reach one call site would be a much bigger,
/// riskier diff than adding one boxed-future crate. `&dyn LambdaInvoker`
/// threads through exactly the same way those existing parameters do.
#[async_trait::async_trait]
pub trait LambdaInvoker: Send + Sync {
    async fn invoke(&self, function_name: &str, payload: &str) -> anyhow::Result<InvokeOutcome>;
}

/// `"hecksagain-#{domain.to_s.downcase}"` (Adapters::Lambda::Client's own
/// constructor, read directly) — the identical string, same casing rule,
/// same prefix, matching `bin/project_deploy`'s own `stack_name =
/// "hecksagain-#{domain_name}"` this Ruby comment already cites. Pure and
/// synchronous on purpose: this is the one piece of `lambda_client.rs`
/// that needs no mock and no `async` at all to prove — see this file's
/// own `tests` module.
pub fn function_name_for(domain: &str) -> String {
    format!("hecksagain-{}", domain.to_lowercase())
}

/// One `PendingCrossDomainReaction`, delivered — `Runtime::
/// PolicyInterpreter#deliver`'s own `{policy:, on:, trigger:, delivered:,
/// reason:}` record shape (policy_interpreter.rb, read directly), minus
/// `on:` (this crate never sees the triggering event's own name, only its
/// payload — kernel::cli's JSON output doesn't carry it, and nothing here
/// needs it). Surfaced in `dispatch::handle`'s own result JSON as a real,
/// visible field — never silently dropped the way a same-domain
/// reaction's own downstream refusal already, deliberately, is
/// (orchestrate.rs's `react_policies`: "A refusal here is swallowed").
/// The DIFFERENCE that earns this its own visible record: a same-domain
/// reaction fails inside THIS process, where a human reading `refusals`
/// already has the full picture; a cross-Lambda delivery crosses a
/// network boundary this process cannot see past on its own, so its
/// outcome — success, target-side refusal, or (via `deliver`'s `Err`
/// path, below) a hard invoke fault — has to be reported explicitly or
/// nobody would ever know it happened at all.
pub struct CrossDomainDeliveryRecord {
    pub policy: String,
    pub target_domain: String,
    pub target_verb: String,
    pub delivered: bool,
    pub reason: Option<String>,
}

impl CrossDomainDeliveryRecord {
    pub fn to_json(&self) -> Value {
        serde_json::json!({
            "policy": self.policy,
            "target_domain": self.target_domain,
            "target_verb": self.target_verb,
            "delivered": self.delivered,
            "reason": self.reason,
        })
    }
}

/// Delivers ONE `PendingCrossDomainReaction` (as its own kernel::cli JSON
/// shape: `{"policy", "target_domain", "target_verb", "payload"}`) — the
/// caller (`dispatch::handle`) hands this the parsed JSON object straight
/// off the wasm module's own output, unwrapped here rather than upstream
/// so this function stays the one place that knows both this module's
/// input shape AND `Adapters::Lambda::Client#dispatch`'s own request
/// shape (`{"verb": verb, "args": args}` — the SAME payload shape a
/// deployed Lambda's own `main.rs` event-handling `match` already reads,
/// this crate's own `body.get("verb")`/`body.get("args")` in `main.rs`).
///
/// TWO KINDS OF "it didn't work," told apart exactly the way Ruby's own
/// chain already tells them apart:
///
///   - A DOMAIN-LEVEL refusal (the target Lambda invoked cleanly, but its
///     own `refusals` array names this verb) is NOT propagated as `Err` —
///     mirrors `Runtime::PolicyInterpreter#deliver`'s own `rescue
///     *DOMAIN_REFUSALS` (which `RemoteRefusal` — the exception
///     `RemoteDispatcher#dispatch` raises for exactly this same
///     condition — is a member of, per lib/hecksagain/runtime/errors.rb).
///     Recorded as `delivered: false`, non-fatal: the command that
///     triggered this reaction already committed and stays committed.
///   - A genuine INVOKE fault (`function_error` — the target function
///     doesn't exist, threw before answering, or a raw AWS SDK error —
///     network, throttling, `AccessDeniedException`) mirrors
///     `Adapters::Lambda::Client#invoke`'s own `raise Runtime::
///     WiringError`, which is NOT a member of `DOMAIN_REFUSALS` and so
///     flies straight out of `deliver` uncaught in Ruby too. This
///     function does the same: returns `Err`, which `dispatch::handle`
///     lets propagate out of the whole call — a real, visible failure of
///     THIS Lambda invocation (surfaced to whatever invoked it, logged by
///     `lambda_runtime`), never silently folded into an ordinary
///     delivery record. It does NOT roll back the local command's own
///     already-committed write — see `dispatch::handle`'s own comment on
///     why cross-domain delivery runs after that transaction commits, not
///     inside it.
pub async fn deliver<L: LambdaInvoker + ?Sized>(invoker: &L, reaction: &Value) -> anyhow::Result<CrossDomainDeliveryRecord> {
    let policy = reaction.get("policy").and_then(Value::as_str).unwrap_or_default().to_string();
    let target_domain = reaction.get("target_domain").and_then(Value::as_str).unwrap_or_default().to_string();
    let target_verb = reaction.get("target_verb").and_then(Value::as_str).unwrap_or_default().to_string();
    let payload = reaction.get("payload").cloned().unwrap_or_else(|| serde_json::json!({}));

    let function_name = function_name_for(&target_domain);
    // `Adapters::Lambda::Client#dispatch`'s own payload shape, verbatim —
    // `{"verb" => verb, "args" => args}` (no `"role"` — a policy reaction
    // is system-triggered, `Dispatcher#reenter`'s own `Caller.without`,
    // already ported into `orchestrate.rs`'s local branch; the identical
    // reasoning applies to the cross-domain branch, which is why no
    // caller role is threaded through this far).
    let request_payload = serde_json::json!({ "verb": target_verb, "args": payload }).to_string();

    let outcome = invoker.invoke(&function_name, &request_payload).await?;

    if outcome.function_error {
        let message = outcome.body.get("errorMessage").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| outcome.body.to_string());
        anyhow::bail!("Lambda {function_name} ({}): {message}", target_verb);
    }

    let target_side_refusal = outcome
        .body
        .get("refusals")
        .and_then(Value::as_array)
        .and_then(|refusals| refusals.iter().find(|r| r.get("verb").and_then(Value::as_str) == Some(target_verb.as_str())));

    let Some(refusal) = target_side_refusal else {
        return Ok(CrossDomainDeliveryRecord { policy, target_domain, target_verb, delivered: true, reason: None });
    };

    Ok(CrossDomainDeliveryRecord {
        policy,
        target_domain,
        target_verb,
        delivered: false,
        reason: refusal.get("error").and_then(Value::as_str).map(String::from),
    })
}

/// THE REAL AWS SDK ADAPTER — the ONLY piece of this file `cargo test`
/// cannot exercise, structurally: it needs a second real domain's own
/// Lambda actually deployed under `hecksagain-<domain>` and reachable
/// with real IAM credentials, neither of which this repository's own
/// test environment has (this worktree has no live AWS access at all).
/// Everything ABOVE this point — function-name computation, request
/// payload shape, refusal-vs-fault classification — is proven by this
/// file's own `tests` module against `LambdaInvoker`, generically; this
/// struct is the thin, structurally-argued-but-unverified-here glue that
/// makes `LambdaInvoker` real. `aws_sdk_lambda::Client::invoke`'s own
/// documented shape (`function_error`/`payload` on the response) is what
/// `deliver`, above, was written against — if that shape is wrong, only a
/// real invoke against a real deployed Lambda would catch it.
pub struct AwsLambdaInvoker {
    client: aws_sdk_lambda::Client,
}

impl AwsLambdaInvoker {
    /// `aws_config`'s own credential/region resolution chain — the SAME
    /// one Ruby's `Aws::Lambda::Client.new(region:)` relies on implicitly
    /// (an IAM role's own environment inside a deployed Lambda; a local
    /// profile/environment otherwise) — nothing hand-rolled there. The
    /// ONE piece built explicitly rather than accepted as either crate's
    /// own default is the HTTP client itself — `Cargo.toml`'s own header
    /// on this dependency explains why (either crate's own "rustls"/
    /// `default` feature actually wires in `aws-lc-rs`, not `ring`).
    pub async fn from_env() -> Self {
        let http_client = aws_smithy_http_client::Builder::new()
            .tls_provider(aws_smithy_http_client::tls::Provider::Rustls(aws_smithy_http_client::tls::rustls_provider::CryptoMode::Ring))
            .build_https();
        let config = aws_config::defaults(aws_config::BehaviorVersion::latest()).http_client(http_client).load().await;
        Self { client: aws_sdk_lambda::Client::new(&config) }
    }
}

/// A `LambdaInvoker` that PANICS if ever actually called — for a caller's
/// own tests to prove a code path that is expected to never reach a
/// cross-domain reaction genuinely doesn't: `dispatch.rs`'s own test
/// suite dispatches only same-domain commands, so wiring this in instead
/// of a real invoker (or `AwsLambdaInvoker`, which would need live AWS
/// credentials those tests don't have) is itself a small, honest
/// assertion — if a future change ever DID cause an unexpected
/// cross-domain delivery attempt in one of those tests, this fails loudly
/// rather than a silent mock quietly accepting a call nobody meant to
/// make. `#[cfg(test)]` — this is a test double, never meant to be
/// reachable from `main.rs`'s own real dispatch path, so it stays out of
/// a non-test build entirely rather than sitting there unused.
#[cfg(test)]
pub struct NeverInvoker;

#[cfg(test)]
#[async_trait::async_trait]
impl LambdaInvoker for NeverInvoker {
    async fn invoke(&self, function_name: &str, _payload: &str) -> anyhow::Result<InvokeOutcome> {
        unreachable!("NeverInvoker: unexpected cross-domain Lambda invoke attempted against {function_name:?}")
    }
}

#[async_trait::async_trait]
impl LambdaInvoker for AwsLambdaInvoker {
    async fn invoke(&self, function_name: &str, payload: &str) -> anyhow::Result<InvokeOutcome> {
        let response = self
            .client
            .invoke()
            .function_name(function_name)
            .payload(aws_sdk_lambda::primitives::Blob::new(payload.as_bytes()))
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("invoking Lambda {function_name}: {e:?}"))?;

        let function_error = response.function_error().is_some();
        let bytes = response.payload().map(|blob| blob.as_ref().to_vec()).unwrap_or_default();
        // A non-JSON or empty body reads as `{}` rather than failing this
        // call outright — `deliver`'s own refusal-scan already treats a
        // body with no `"refusals"` array as "nothing refused", the
        // correct reading for an empty/malformed body too; `function_error`
        // (checked separately, above) is what actually signals a fault.
        let body: Value = serde_json::from_slice(&bytes).unwrap_or_else(|_| serde_json::json!({}));

        Ok(InvokeOutcome { body, function_error })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn function_name_matches_rubys_own_hecksagain_dash_domain_convention() {
        assert_eq!(function_name_for("Compliance"), "hecksagain-compliance");
        assert_eq!(function_name_for("Notifications"), "hecksagain-notifications");
        // Ruby's own `.downcase`, not a snake_case transform — a domain
        // spelled with an internal capital stays one lowercase word, the
        // same string `"hecksagain-#{domain.to_s.downcase}"` would produce.
        assert_eq!(function_name_for("Banking"), "hecksagain-banking");
    }

    /// Records every call it receives (function name + payload, for the
    /// "invoked with the right shape" assertions) and answers with
    /// whatever canned outcome the test configured — no network, no AWS
    /// SDK type, just `LambdaInvoker` itself.
    struct MockLambdaInvoker {
        response: Result<InvokeOutcome, String>,
        calls: Mutex<Vec<(String, String)>>,
    }

    impl MockLambdaInvoker {
        fn answering(body: Value, function_error: bool) -> Self {
            Self { response: Ok(InvokeOutcome { body, function_error }), calls: Mutex::new(Vec::new()) }
        }

        fn failing(message: &str) -> Self {
            Self { response: Err(message.to_string()), calls: Mutex::new(Vec::new()) }
        }
    }

    #[async_trait::async_trait]
    impl LambdaInvoker for MockLambdaInvoker {
        async fn invoke(&self, function_name: &str, payload: &str) -> anyhow::Result<InvokeOutcome> {
            self.calls.lock().unwrap().push((function_name.to_string(), payload.to_string()));
            match &self.response {
                Ok(outcome) => Ok(InvokeOutcome { body: outcome.body.clone(), function_error: outcome.function_error }),
                Err(message) => anyhow::bail!("{message}"),
            }
        }
    }

    fn reaction(target_domain: &str, target_verb: &str) -> Value {
        serde_json::json!({
            "policy": "ReviewOnFreeze",
            "target_domain": target_domain,
            "target_verb": target_verb,
            "payload": { "number": { "value": "acct-1" } },
        })
    }

    #[tokio::test]
    async fn delivers_and_invokes_the_computed_function_name_with_the_verb_args_payload_shape() {
        let invoker = MockLambdaInvoker::answering(serde_json::json!({ "refusals": [] }), false);

        let record = deliver(&invoker, &reaction("Compliance", "Compliance::AccountFreezeReview.Open")).await.unwrap();

        assert!(record.delivered);
        assert_eq!(record.reason, None);
        assert_eq!(record.target_domain, "Compliance");

        let calls = invoker.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        let (function_name, payload) = &calls[0];
        assert_eq!(function_name, "hecksagain-compliance");
        let sent: Value = serde_json::from_str(payload).unwrap();
        assert_eq!(sent["verb"], "Compliance::AccountFreezeReview.Open");
        assert_eq!(sent["args"]["number"]["value"], "acct-1");
    }

    #[tokio::test]
    async fn a_target_side_refusal_is_recorded_non_fatally_not_raised() {
        let invoker = MockLambdaInvoker::answering(
            serde_json::json!({ "refusals": [ { "verb": "Compliance::AccountFreezeReview.Open", "error": "already under review" } ] }),
            false,
        );

        let record = deliver(&invoker, &reaction("Compliance", "Compliance::AccountFreezeReview.Open")).await.unwrap();

        assert!(!record.delivered);
        assert_eq!(record.reason.as_deref(), Some("already under review"));
    }

    #[tokio::test]
    async fn a_refusal_for_a_different_verb_in_the_same_response_does_not_count_as_this_ones() {
        // Same shape RemoteDispatcher#dispatch's own scan guards against —
        // a Lambda-routed domain's response can legitimately carry
        // refusals from OTHER steps in its own replay; only a refusal
        // naming THIS verb is this delivery's own outcome.
        let invoker = MockLambdaInvoker::answering(
            serde_json::json!({ "refusals": [ { "verb": "Compliance.SomethingElse", "error": "unrelated" } ] }),
            false,
        );

        let record = deliver(&invoker, &reaction("Compliance", "Compliance::AccountFreezeReview.Open")).await.unwrap();

        assert!(record.delivered);
    }

    #[tokio::test]
    async fn a_function_error_response_is_a_hard_failure_not_a_delivery_record() {
        // Mirrors `Adapters::Lambda::Client#invoke`'s own `raise Runtime::
        // WiringError` on `response.function_error` — NOT a member of
        // Ruby's own DOMAIN_REFUSALS, so it flies rather than getting
        // swallowed into an ordinary `delivered: false` record.
        let invoker = MockLambdaInvoker::answering(serde_json::json!({ "errorMessage": "unhandled panic" }), true);

        let outcome = deliver(&invoker, &reaction("Compliance", "Compliance::AccountFreezeReview.Open")).await;

        assert!(outcome.is_err(), "a function_error response must propagate as Err, not a delivered:false record");
    }

    #[tokio::test]
    async fn an_invoke_that_never_reaches_the_target_at_all_is_also_a_hard_failure() {
        // The OTHER real invoke fault — the function simply doesn't
        // exist, or the call never completes (network, throttling,
        // AccessDeniedException) — never even reaches Ok(InvokeOutcome).
        let invoker = MockLambdaInvoker::failing("ResourceNotFoundException: function not found");

        let outcome = deliver(&invoker, &reaction("Notifications", "Notifications.Send")).await;

        assert!(outcome.is_err());
    }
}
