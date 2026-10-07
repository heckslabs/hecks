//! Fetches secrets from Secrets Manager at runtime, not via CloudFormation dynamic references.
//! A resolved reference lands decrypted in function configuration, readable account-wide.

pub struct AwsSecretFetcher {
    client: aws_sdk_secretsmanager::Client,
}

impl AwsSecretFetcher {
    // Same credential chain and ring-backed HTTP client as `AwsLambdaInvoker::from_env`; the
    // default features would wire in aws-lc-rs instead (see Cargo.toml).
    pub async fn from_env() -> Self {
        let http_client = aws_smithy_http_client::Builder::new()
            .tls_provider(aws_smithy_http_client::tls::Provider::Rustls(aws_smithy_http_client::tls::rustls_provider::CryptoMode::Ring))
            .build_https();
        let config = aws_config::defaults(aws_config::BehaviorVersion::latest()).http_client(http_client).load().await;
        Self { client: aws_sdk_secretsmanager::Client::new(&config) }
    }

    /// The secret's whole `SecretString`, undecoded. `secret_id` is a full ARN or a name.
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

    /// Like `fetch_secret_string`, but a secret that does not exist yet is
    /// `None`, not an error: the payment keys' secret is only created by the
    /// first save.
    pub async fn fetch_secret_string_if_present(&self, secret_id: &str) -> anyhow::Result<Option<String>> {
        match self.client.get_secret_value().secret_id(secret_id).send().await {
            Ok(response) => Ok(response.secret_string().map(|s| s.to_string())),
            Err(e) if e.as_service_error().is_some_and(|service| service.is_resource_not_found_exception()) => Ok(None),
            Err(_) => Err(anyhow::anyhow!("reading secret {secret_id} failed")),
        }
    }

    /// Replaces the secret's `SecretString`, creating the secret the first time.
    /// The errors name the secret and never carry the value.
    pub async fn put_secret_string(&self, secret_id: &str, value: &str) -> anyhow::Result<()> {
        match self.client.put_secret_value().secret_id(secret_id).secret_string(value).send().await {
            Ok(_) => Ok(()),
            Err(e) if e.as_service_error().is_some_and(|service| service.is_resource_not_found_exception()) => {
                self.client
                    .create_secret()
                    .name(secret_id)
                    .secret_string(value)
                    .send()
                    .await
                    .map(|_| ())
                    .map_err(|_| anyhow::anyhow!("creating secret {secret_id} failed"))
            }
            Err(_) => Err(anyhow::anyhow!("writing secret {secret_id} failed")),
        }
    }
}

/// One named string field out of a secret's JSON `SecretString`.
///
/// Pure, so it is tested without a client.
pub fn extract_field(secret_json: &str, field: &str) -> Result<String, String> {
    let value: serde_json::Value =
        serde_json::from_str(secret_json).map_err(|e| format!("secret's SecretString isn't valid JSON: {e}"))?;
    value
        .get(field)
        .and_then(|p| p.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| format!("secret's SecretString has no string {field:?} field"))
}

/// One named string field out of a secret's JSON `SecretString`, or `None` when the secret does not
/// carry it (or is not JSON, or the field is blank). For a field a secret may have and may not.
pub fn optional_field(secret_json: &str, field: &str) -> Option<String> {
    extract_field(secret_json, field).ok().filter(|value| !value.trim().is_empty())
}

/// The `postgres://` URL for a database secret.
///
/// The user is the secret's `username`, which is `postgres` for RDS's managed master secret and a
/// client's own role for a database shared with other clients; a secret without one is read as
/// `postgres`. The port is the secret's `port` when it has one, else 5432. The password goes in
/// literal, as before: the URL parser downstream never percent-decodes it, so a client's generated
/// password is letters and digits only.
pub fn database_url(secret_json: &str, host: &str, database: &str) -> Result<String, String> {
    let password = extract_field(secret_json, "password")?;
    let user = extract_field(secret_json, "username").unwrap_or_else(|_| "postgres".to_string());
    let port = serde_json::from_str::<serde_json::Value>(secret_json)
        .ok()
        .and_then(|v| v.get("port").and_then(|p| p.as_u64().or_else(|| p.as_str().and_then(|s| s.parse().ok()))))
        .unwrap_or(5432);
    Ok(format!("postgres://{user}:{password}@{host}:{port}/{database}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_optional_field_is_read_when_present_and_none_when_absent_blank_or_not_json() {
        let json = r#"{"api_key":"re_1","webhook_secret":"whsec_abc","blank":"  "}"#;
        assert_eq!(optional_field(json, "webhook_secret").as_deref(), Some("whsec_abc"));
        assert_eq!(optional_field(json, "missing"), None);
        assert_eq!(optional_field(json, "blank"), None);
        assert_eq!(optional_field("not json", "webhook_secret"), None);
    }

    #[test]
    fn a_master_secret_logs_in_as_postgres_on_the_default_port() {
        let json = r#"{"username":"postgres","password":"abc123"}"#;
        assert_eq!(database_url(json, "db.example", "app").unwrap(), "postgres://postgres:abc123@db.example:5432/app");
    }

    #[test]
    fn a_clients_own_secret_logs_in_as_its_role() {
        let json = r#"{"username":"acme","password":"s3cr3t","host":"db.example","port":5433,"dbname":"acme"}"#;
        assert_eq!(database_url(json, "db.example", "acme").unwrap(), "postgres://acme:s3cr3t@db.example:5433/acme");
    }

    #[test]
    fn a_secret_with_no_username_is_read_as_postgres() {
        assert_eq!(database_url(r#"{"password":"pw"}"#, "h", "d").unwrap(), "postgres://postgres:pw@h:5432/d");
    }

    #[test]
    fn a_port_written_as_text_is_read() {
        assert_eq!(database_url(r#"{"password":"pw","port":"6000"}"#, "h", "d").unwrap(), "postgres://postgres:pw@h:6000/d");
    }

    #[test]
    fn a_secret_with_no_password_is_refused() {
        assert!(database_url(r#"{"username":"acme"}"#, "h", "d").is_err());
    }

    #[test]
    fn extracts_the_named_field_from_the_generated_secret_shape() {
        assert_eq!(
            extract_field(r#"{"username":"postgres","password":"abc123"}"#, "password").unwrap(),
            "abc123"
        );
    }

    #[test]
    fn extracts_either_field_from_a_two_field_secret() {
        let json = r#"{"client_id":"id-1","client_secret":"secret-1"}"#;
        assert_eq!(extract_field(json, "client_id").unwrap(), "id-1");
        assert_eq!(extract_field(json, "client_secret").unwrap(), "secret-1");
    }

    #[test]
    fn refuses_a_missing_field() {
        assert!(extract_field(r#"{"username":"postgres"}"#, "password").is_err());
    }

    #[test]
    fn refuses_invalid_json() {
        assert!(extract_field("not json", "password").is_err());
    }
}
