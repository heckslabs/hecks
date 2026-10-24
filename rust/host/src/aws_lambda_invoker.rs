//! The AWS adapter behind `lambda_client::LambdaInvoker`: invokes another domain's Lambda
//! function through the AWS SDK.

use crate::lambda_client::{InvokeOutcome, LambdaInvoker};
use serde_json::Value;

/// The process's one Lambda client, its credentials and region resolved at boot.
///
/// Untestable here: it needs a real deployed Lambda and live AWS credentials, neither of which
/// this repository's test environment has.
pub struct AwsLambdaInvoker {
    client: aws_sdk_lambda::Client,
}

impl AwsLambdaInvoker {
    /// Builds the client from the standard AWS environment and config chain, over an explicit
    /// rustls+ring HTTP client: neither crate's own default feature wires in `ring` (see
    /// Cargo.toml's note on this dependency).
    pub async fn from_env() -> Self {
        let http_client = aws_smithy_http_client::Builder::new()
            .tls_provider(aws_smithy_http_client::tls::Provider::Rustls(
                aws_smithy_http_client::tls::rustls_provider::CryptoMode::Ring,
            ))
            .build_https();
        let config = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .http_client(http_client)
            .load()
            .await;
        Self {
            client: aws_sdk_lambda::Client::new(&config),
        }
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
        let bytes = response
            .payload()
            .map(|blob| blob.as_ref().to_vec())
            .unwrap_or_default();
        // A non-JSON/empty body reads as `{}` rather than failing the call;
        // `function_error` (checked above) is what actually signals a fault.
        let body: Value = serde_json::from_slice(&bytes).unwrap_or_else(|_| serde_json::json!({}));

        Ok(InvokeOutcome {
            body,
            function_error,
        })
    }
}
