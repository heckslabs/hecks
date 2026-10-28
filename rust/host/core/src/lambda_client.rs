//! Delivers a `PendingCrossDomainReaction` to another domain's Lambda function,
//! mirroring `Adapters::Lambda::Client`'s invoke/dispatch shape. This is the port; the AWS
//! adapter behind it is `aws_lambda_invoker`.

use serde_json::Value;

// Decoupled from the AWS SDK's own response type so a mock never needs one.
pub struct InvokeOutcome {
    pub body: Value,
    pub function_error: bool,
}

// `&dyn`, not a generic — the call chain reaching this is already deep, and making
// every function in it generic over `L: LambdaInvoker` would be a much bigger diff.
#[async_trait::async_trait]
pub trait LambdaInvoker: Send + Sync {
    async fn invoke(&self, function_name: &str, payload: &str) -> anyhow::Result<InvokeOutcome>;
}

// Mirrors Ruby's `"hecks-#{domain.downcase}"` — deployed stack names depend on
// this exact casing, down to a word-final capital sigma, so it lowercases as Ruby does.
pub fn function_name_for(domain: &str) -> String {
    format!("hecks-{}", crate::hecks_naming::ruby_downcase(domain))
}

// Mirrors `PolicyInterpreter#deliver`'s record shape, minus `on:` — this crate
// never sees the triggering event's own name, only its payload.
#[derive(Debug)]
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

// A target-side refusal returns `delivered: false`; a genuine invoke fault
// (`function_error`, or a hard `Err` from `invoke`) returns `Err` instead.
pub async fn deliver<L: LambdaInvoker + ?Sized>(
    invoker: &L,
    reaction: &Value,
) -> anyhow::Result<CrossDomainDeliveryRecord> {
    let policy = reaction
        .get("policy")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let target_domain = reaction
        .get("target_domain")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let target_verb = reaction
        .get("target_verb")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let payload = reaction
        .get("payload")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));

    let function_name = function_name_for(&target_domain);
    // No `"role"` — a policy reaction is system-triggered, the same reasoning
    // `orchestrate.rs`'s local branch already applies via `Caller.without`.
    let request_payload = serde_json::json!({ "verb": target_verb, "args": payload }).to_string();

    let outcome = invoker.invoke(&function_name, &request_payload).await?;

    if outcome.function_error {
        let message = outcome
            .body
            .get("errorMessage")
            .and_then(Value::as_str)
            .map_or_else(|| outcome.body.to_string(), str::to_string);
        anyhow::bail!("Lambda {function_name} ({target_verb}): {message}");
    }

    let target_side_refusal = outcome
        .body
        .get("refusals")
        .and_then(Value::as_array)
        .and_then(|refusals| {
            refusals
                .iter()
                .find(|r| r.get("verb").and_then(Value::as_str) == Some(target_verb.as_str()))
        });

    let Some(refusal) = target_side_refusal else {
        return Ok(CrossDomainDeliveryRecord {
            policy,
            target_domain,
            target_verb,
            delivered: true,
            reason: None,
        });
    };

    Ok(CrossDomainDeliveryRecord {
        policy,
        target_domain,
        target_verb,
        delivered: false,
        reason: refusal
            .get("error")
            .and_then(Value::as_str)
            .map(String::from),
    })
}

// Kept small — shares the invoking Lambda's own tight execution-time budget
// with every other cross-domain reaction still queued behind it.
pub const MAX_DELIVERY_ATTEMPTS: u32 = 3;

// Carries what `journal::record_dead_letter` needs; this file stays free of
// Postgres itself.
#[derive(Debug)]
pub struct DeliveryFailure {
    pub policy: String,
    pub target_domain: String,
    pub target_verb: String,
    pub payload: Value,
    pub error: anyhow::Error,
    pub attempts: u32,
}

// Retries only a genuine invoke fault (`Err`); a clean `Ok(delivered: false)`
// refusal is a business outcome and is never retried.
// `DeliveryFailure` carries the whole reaction for the dead letter, so its size is intended.
#[allow(clippy::result_large_err)]
pub async fn deliver_with_retry<L: LambdaInvoker + ?Sized>(
    invoker: &L,
    reaction: &Value,
) -> Result<CrossDomainDeliveryRecord, DeliveryFailure> {
    let mut last_error = None;

    for attempt in 1..=MAX_DELIVERY_ATTEMPTS {
        match deliver(invoker, reaction).await {
            Ok(record) => return Ok(record),
            Err(error) => {
                last_error = Some(error);
                if attempt < MAX_DELIVERY_ATTEMPTS {
                    let backoff_ms = 100u64 * (1 << (attempt - 1));
                    tokio::time::sleep(std::time::Duration::from_millis(backoff_ms)).await;
                }
            }
        }
    }

    Err(DeliveryFailure {
        policy: reaction
            .get("policy")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        target_domain: reaction
            .get("target_domain")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        target_verb: reaction
            .get("target_verb")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        payload: reaction
            .get("payload")
            .cloned()
            .unwrap_or_else(|| serde_json::json!({})),
        // The loop runs at least once and every `Err` arm sets `last_error`, so the fallback is
        // unreachable; it exists only so a zero attempt budget still reports a failure.
        error: last_error.unwrap_or_else(|| anyhow::anyhow!("no delivery attempt ran")),
        attempts: MAX_DELIVERY_ATTEMPTS,
    })
}

// Panics if invoked — asserts that same-domain-only test suites never
// trigger a cross-domain delivery.
#[cfg(any(test, feature = "test-support"))]
pub struct NeverInvoker;

#[cfg(any(test, feature = "test-support"))]
#[async_trait::async_trait]
impl LambdaInvoker for NeverInvoker {
    async fn invoke(&self, function_name: &str, _payload: &str) -> anyhow::Result<InvokeOutcome> {
        unreachable!("NeverInvoker: unexpected cross-domain Lambda invoke attempted against {function_name:?}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn function_name_matches_rubys_own_hecks_dash_domain_convention() {
        assert_eq!(function_name_for("Compliance"), "hecks-compliance");
        assert_eq!(function_name_for("Notifications"), "hecks-notifications");
        // Ruby's `.downcase`, not snake_case — an internally-capitalized domain
        // stays one lowercase word.
        assert_eq!(function_name_for("Banking"), "hecks-banking");
    }

    // spec/fixtures/stack_name_vectors.json is asserted by spec/deploy_stack_names_spec.rb against
    // all four Ruby copies of the formula, so a drift in any of them fails a test.
    fn stack_name_vectors() -> Value {
        serde_json::from_str(include_str!(
            "../../../../spec/fixtures/stack_name_vectors.json"
        ))
        .unwrap()
    }

    #[test]
    fn function_name_matches_every_shared_stack_name_vector() {
        let vectors = stack_name_vectors();
        let rows = vectors["rows"].as_array().unwrap();
        assert!(!rows.is_empty());
        for row in rows {
            let domain = row["domain"].as_str().unwrap();
            assert_eq!(
                function_name_for(domain),
                row["name"].as_str().unwrap(),
                "{domain}"
            );
        }
    }

    // Records each call and answers with whatever canned outcome the test configured.
    struct MockLambdaInvoker {
        response: Result<InvokeOutcome, String>,
        calls: Mutex<Vec<(String, String)>>,
    }

    impl MockLambdaInvoker {
        fn answering(body: Value, function_error: bool) -> Self {
            Self {
                response: Ok(InvokeOutcome {
                    body,
                    function_error,
                }),
                calls: Mutex::new(Vec::new()),
            }
        }

        fn failing(message: &str) -> Self {
            Self {
                response: Err(message.to_string()),
                calls: Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait::async_trait]
    impl LambdaInvoker for MockLambdaInvoker {
        async fn invoke(
            &self,
            function_name: &str,
            payload: &str,
        ) -> anyhow::Result<InvokeOutcome> {
            self.calls
                .lock()
                .unwrap()
                .push((function_name.to_string(), payload.to_string()));
            match &self.response {
                Ok(outcome) => Ok(InvokeOutcome {
                    body: outcome.body.clone(),
                    function_error: outcome.function_error,
                }),
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

        let record = deliver(&invoker, &reaction("Compliance", "Compliance::Review.Open"))
            .await
            .unwrap();

        assert!(record.delivered);
        assert_eq!(record.reason, None);
        assert_eq!(record.target_domain, "Compliance");

        let calls = invoker.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        let (function_name, payload) = &calls[0];
        assert_eq!(function_name, "hecks-compliance");
        let sent: Value = serde_json::from_str(payload).unwrap();
        assert_eq!(sent["verb"], "Compliance::Review.Open");
        assert_eq!(sent["args"]["number"]["value"], "acct-1");
    }

    #[tokio::test]
    async fn a_target_side_refusal_is_recorded_non_fatally_not_raised() {
        let invoker = MockLambdaInvoker::answering(
            serde_json::json!({ "refusals": [ { "verb": "Compliance::Review.Open", "error": "already under review" } ] }),
            false,
        );

        let record = deliver(&invoker, &reaction("Compliance", "Compliance::Review.Open"))
            .await
            .unwrap();

        assert!(!record.delivered);
        assert_eq!(record.reason.as_deref(), Some("already under review"));
    }

    #[tokio::test]
    async fn a_refusal_for_a_different_verb_in_the_same_response_does_not_count_as_this_ones() {
        // A response can legitimately carry refusals from other steps; only a
        // refusal naming this verb counts as this delivery's outcome.
        let invoker = MockLambdaInvoker::answering(
            serde_json::json!({ "refusals": [ { "verb": "Compliance.SomethingElse", "error": "unrelated" } ] }),
            false,
        );

        let record = deliver(&invoker, &reaction("Compliance", "Compliance::Review.Open"))
            .await
            .unwrap();

        assert!(record.delivered);
    }

    #[tokio::test]
    async fn a_function_error_response_is_a_hard_failure_not_a_delivery_record() {
        // Mirrors Ruby's `raise WiringError` on `function_error` — not a domain
        // refusal, so it propagates rather than becoming a `delivered: false` record.
        let invoker = MockLambdaInvoker::answering(
            serde_json::json!({ "errorMessage": "unhandled panic" }),
            true,
        );

        let outcome = deliver(&invoker, &reaction("Compliance", "Compliance::Review.Open")).await;

        assert!(
            outcome.is_err(),
            "a function_error response must propagate as Err, not a delivered:false record"
        );
    }

    #[tokio::test]
    async fn an_invoke_that_never_reaches_the_target_at_all_is_also_a_hard_failure() {
        // The function doesn't exist, or the call never completes (network,
        // throttling, AccessDenied) — never even reaches `Ok(InvokeOutcome)`.
        let invoker = MockLambdaInvoker::failing("ResourceNotFoundException: function not found");

        let outcome = deliver(&invoker, &reaction("Notifications", "Notifications.Send")).await;

        assert!(outcome.is_err());
    }

    // Fails the first `fail_count` calls, then succeeds — the shape of a
    // transient throttle that clears before a retry limit is hit.
    struct FlakyLambdaInvoker {
        fail_count: std::sync::atomic::AtomicU32,
        calls: Mutex<Vec<String>>,
    }

    impl FlakyLambdaInvoker {
        fn failing_then_succeeding(fail_count: u32) -> Self {
            Self {
                fail_count: std::sync::atomic::AtomicU32::new(fail_count),
                calls: Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait::async_trait]
    impl LambdaInvoker for FlakyLambdaInvoker {
        async fn invoke(
            &self,
            function_name: &str,
            _payload: &str,
        ) -> anyhow::Result<InvokeOutcome> {
            self.calls.lock().unwrap().push(function_name.to_string());
            let remaining = self.fail_count.load(std::sync::atomic::Ordering::SeqCst);
            if remaining > 0 {
                self.fail_count
                    .store(remaining - 1, std::sync::atomic::Ordering::SeqCst);
                anyhow::bail!("ThrottlingException: rate exceeded");
            }
            Ok(InvokeOutcome {
                body: serde_json::json!({ "refusals": [] }),
                function_error: false,
            })
        }
    }

    #[tokio::test]
    async fn deliver_with_retry_rides_out_a_transient_fault_that_clears_before_attempts_run_out() {
        let invoker = FlakyLambdaInvoker::failing_then_succeeding(MAX_DELIVERY_ATTEMPTS - 1);

        let record =
            deliver_with_retry(&invoker, &reaction("Compliance", "Compliance::Review.Open"))
                .await
                .expect("should succeed once the fault clears, within MAX_DELIVERY_ATTEMPTS");

        assert!(record.delivered);
        assert_eq!(
            invoker.calls.lock().unwrap().len(),
            MAX_DELIVERY_ATTEMPTS as usize,
            "should have retried exactly up to the successful attempt"
        );
    }

    #[tokio::test]
    async fn deliver_with_retry_never_retries_a_clean_domain_side_refusal() {
        // A clean refusal is `Ok(delivered: false)`, a business decision — retrying
        // it would not change what the target domain decided.
        let invoker = MockLambdaInvoker::answering(
            serde_json::json!({ "refusals": [ { "verb": "Compliance::Review.Open", "error": "already under review" } ] }),
            false,
        );

        let record =
            deliver_with_retry(&invoker, &reaction("Compliance", "Compliance::Review.Open"))
                .await
                .expect("a domain-side refusal is Ok, not a DeliveryFailure");

        assert!(!record.delivered);
        assert_eq!(
            invoker.calls.lock().unwrap().len(),
            1,
            "a clean refusal should never be retried"
        );
    }

    #[tokio::test]
    async fn deliver_with_retry_gives_up_after_max_attempts_and_carries_everything_a_dead_letter_needs(
    ) {
        let invoker = MockLambdaInvoker::failing("ResourceNotFoundException: function not found");

        let failure =
            deliver_with_retry(&invoker, &reaction("Notifications", "Notifications.Send"))
                .await
                .expect_err("a persistent fault should exhaust every attempt and fail");

        assert_eq!(failure.policy, "ReviewOnFreeze");
        assert_eq!(failure.target_domain, "Notifications");
        assert_eq!(failure.target_verb, "Notifications.Send");
        assert_eq!(
            failure.payload,
            serde_json::json!({ "number": { "value": "acct-1" } })
        );
        assert_eq!(failure.attempts, MAX_DELIVERY_ATTEMPTS);
        assert!(format!("{:#}", failure.error).contains("ResourceNotFoundException"));
        assert_eq!(
            invoker.calls.lock().unwrap().len(),
            MAX_DELIVERY_ATTEMPTS as usize
        );
    }
}
