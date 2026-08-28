// FETCHES THE DB PASSWORD AT RUNTIME, not deploy time -- template.yaml
// (bin/project_deploy) used to compose DATABASE_URL itself via a
// CloudFormation `{{resolve:secretsmanager:...}}` dynamic reference
// baked straight into this function's own Environment.Variables. That
// reference genuinely never touches the template or the CloudFormation
// console as plaintext -- but once it resolves INTO a Lambda's
// Environment.Variables entry, the resolved plaintext lands in the
// function's own configuration: `lambda:GetFunctionConfiguration`
// returns it decrypted, to any principal holding read-only account
// access. AWS's own guidance is exactly what this module does instead:
// fetch the secret at runtime, over the SDK, and never let
// CloudFormation/Lambda configuration see it at all. main.rs's own
// cold-start reads DB_SECRET_ARN/DB_HOST/DB_NAME (none of which are
// secrets themselves -- an ARN, an endpoint, and a database name
// authenticate nothing on their own) and calls this module once.
//
// NO TRAIT/MOCK BOUNDARY HERE, unlike lambda_client.rs's own
// LambdaInvoker -- that trait exists because dispatch.rs's real test
// suite threads through many call sites and needs to prove behavior
// without live AWS credentials. This module has exactly one call site
// (main.rs's own cold start, never exercised by a test), so the only
// piece worth proving in isolation is the one pure, synchronous parse
// below -- `extract_password` -- which this file's own `tests` module
// does directly, with no client and no mock at all. `AwsSecretFetcher`
// itself is real AWS SDK glue, structurally unverifiable here, same
// honest limitation lambda_client.rs's own `AwsLambdaInvoker` states
// about itself.

pub struct AwsSecretFetcher {
    client: aws_sdk_secretsmanager::Client,
}

impl AwsSecretFetcher {
    // Same credential/region resolution chain, same explicit
    // ring-backed HTTP client (not either crate's own "rustls"/
    // "default" feature, which wires in aws-lc-rs instead -- see
    // Cargo.toml's own header) as `lambda_client.rs`'s
    // `AwsLambdaInvoker::from_env` -- the identical pattern, applied to
    // a second AWS service client in this same crate.
    pub async fn from_env() -> Self {
        let http_client = aws_smithy_http_client::Builder::new()
            .tls_provider(aws_smithy_http_client::tls::Provider::Rustls(aws_smithy_http_client::tls::rustls_provider::CryptoMode::Ring))
            .build_https();
        let config = aws_config::defaults(aws_config::BehaviorVersion::latest()).http_client(http_client).load().await;
        Self { client: aws_sdk_secretsmanager::Client::new(&config) }
    }

    /// The secret's whole `SecretString`, undecoded -- `secret_id` is a
    /// full ARN or a name, either works against `GetSecretValue`.
    /// Callers that need one JSON field out of it (the generated
    /// RDS/Aurora secret's own `{"username":"postgres","password":"..."}`
    /// shape, `GenerateSecretString`'s template in bin/project_deploy)
    /// parse it themselves -- `extract_password`, below, for this
    /// crate's one caller.
    pub async fn fetch_secret_string(&self, secret_id: &str) -> anyhow::Result<String> {
        let response = self
            .client
            .get_secret_value()
            .secret_id(secret_id)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("fetching secret {secret_id}: {e:?}"))?;
        response
            .secret_string()
            .map(|s| s.to_string())
            .ok_or_else(|| anyhow::anyhow!("secret {secret_id} has no SecretString"))
    }
}

/// The one JSON field this crate ever needs out of a fetched secret --
/// `GenerateSecretString`'s own `{"username":"postgres"}` template plus
/// a generated `password` key (bin/project_deploy's own
/// `#{db_id}Secret`/plain-RDS `ManageMasterUserPassword` comment). Pure
/// and synchronous, deliberately kept separate from the network fetch
/// above so it needs no client and no mock to prove.
pub fn extract_password(secret_json: &str) -> Result<String, String> {
    let value: serde_json::Value =
        serde_json::from_str(secret_json).map_err(|e| format!("secret's SecretString isn't valid JSON: {e}"))?;
    value
        .get("password")
        .and_then(|p| p.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| "secret's SecretString has no string \"password\" field".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_password_from_the_generated_secret_shape() {
        assert_eq!(
            extract_password(r#"{"username":"postgres","password":"abc123"}"#).unwrap(),
            "abc123"
        );
    }

    #[test]
    fn refuses_a_missing_password_field() {
        assert!(extract_password(r#"{"username":"postgres"}"#).is_err());
    }

    #[test]
    fn refuses_invalid_json() {
        assert!(extract_password("not json").is_err());
    }
}
