//! What a site must know to verify a platform sign-in token, validated before anything uses it.
//!
//! The values are the issuer's address, the address of its key set, this site's reference, and the
//! environment this site runs as. A token is accepted only if it names exactly these. Validation
//! happens when the value is built, so a mistake (an `http` issuer, a trailing slash that would make
//! every token fail the exact `iss` comparison, an environment typo) stops the boot rather than
//! silently locking everyone out or, worse, letting something through.
//!
//! Nothing here reads the process environment: [`PlatformSigninConfig::from_env_map`] takes a map
//! the caller built, and an error names the variable and the kind of mistake but never the value,
//! because a mistyped value is often a pasted secret.

use std::collections::HashMap;
use std::fmt;

/// The variable holding the issuer's address, which is also the exact `iss` every token must carry.
pub const ISSUER_URL_VARIABLE: &str = "PLATFORM_ISSUER_URL";
/// The variable holding the address of the issuer's key set (optional; derived from the issuer).
pub const JWKS_URL_VARIABLE: &str = "PLATFORM_JWKS_URL";
/// The variable holding this site's reference, which is the exact `aud` every token must carry.
pub const SITE_ID_VARIABLE: &str = "PLATFORM_SITE_ID";
/// The variable holding the environment this site runs as, the exact `env` every token must carry.
pub const ENVIRONMENT_VARIABLE: &str = "PLATFORM_ENVIRONMENT";

/// Seconds of clock difference tolerated on `nbf` and `exp`.
pub const DEFAULT_SKEW_SECONDS: i64 = 30;
/// The longest a token may live, `exp - iat`, in seconds.
pub const DEFAULT_MAX_LIFETIME_SECONDS: i64 = 60;
/// The longest token accepted, in bytes; longer ones are refused before they are parsed.
pub const DEFAULT_MAX_TOKEN_BYTES: usize = 4096;
/// The path, under the issuer, where its key set is served when no address is configured.
pub const DEFAULT_JWKS_PATH: &str = "/.well-known/jwks.json";

/// The environments an issuer signs tokens for.
pub const ENVIRONMENTS: [&str; 2] = ["production", "staging"];

/// The pinned facts a verifier checks every token against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlatformSigninConfig {
    pub issuer_url: String,
    pub jwks_url: String,
    pub site_id: String,
    pub environment: String,
    pub skew_seconds: i64,
    pub max_lifetime_seconds: i64,
    pub max_token_bytes: usize,
}

/// What was wrong with a configured value, without the value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigProblem {
    Missing,
    NotHttps,
    CredentialsInUrl,
    PathQueryOrFragment,
    BadHost,
    UpperCase,
    BadShape,
    WrongHostForIssuer,
    NotAnEnvironment,
}

impl ConfigProblem {
    fn describe(self) -> &'static str {
        match self {
            ConfigProblem::Missing => "is not set",
            ConfigProblem::NotHttps => "must be an https URL",
            ConfigProblem::CredentialsInUrl => "must not carry credentials",
            ConfigProblem::PathQueryOrFragment => "must not carry a path, query or fragment (no trailing slash)",
            ConfigProblem::BadHost => "must name a plain lowercase host and an optional port",
            ConfigProblem::UpperCase => "must be lowercase",
            ConfigProblem::BadShape => "has an invalid shape",
            ConfigProblem::WrongHostForIssuer => "must be on the issuer's host",
            ConfigProblem::NotAnEnvironment => "must be production or staging",
        }
    }
}

/// A refused configuration: which variable, and what kind of mistake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConfigError {
    pub variable: &'static str,
    pub problem: ConfigProblem,
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.variable, self.problem.describe())
    }
}

impl std::error::Error for ConfigError {}

impl PlatformSigninConfig {
    /// Builds a configuration from explicit values, with the default skew, lifetime and size cap.
    ///
    /// The values are taken as given and not validated: this is the constructor for tests and for
    /// callers that have already validated. Use [`PlatformSigninConfig::from_env_map`] for input
    /// that came from outside.
    pub fn new(issuer_url: &str, jwks_url: &str, site_id: &str, environment: &str) -> Self {
        let _ = (issuer_url, jwks_url, site_id, environment);
        todo!("PlatformSigninConfig::new")
    }

    /// Builds a validated configuration from a map of variable names to values.
    ///
    /// # Errors
    ///
    /// Returns a [`ConfigError`] naming the first variable that is missing or malformed. The error
    /// never contains the value.
    pub fn from_env_map(vars: &HashMap<String, String>) -> Result<Self, ConfigError> {
        let _ = vars;
        todo!("PlatformSigninConfig::from_env_map")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn good() -> HashMap<String, String> {
        [
            (ISSUER_URL_VARIABLE, "https://issuer.example"),
            (SITE_ID_VARIABLE, "site-a"),
            (ENVIRONMENT_VARIABLE, "production"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
    }

    fn with(name: &str, value: &str) -> HashMap<String, String> {
        let mut vars = good();
        vars.insert(name.to_string(), value.to_string());
        vars
    }

    fn refusal(vars: &HashMap<String, String>) -> ConfigError {
        PlatformSigninConfig::from_env_map(vars).expect_err("must be refused")
    }

    #[test]
    fn explicit_values_get_the_default_windows() {
        let c = PlatformSigninConfig::new("https://issuer.example", "https://issuer.example/k", "site-a", "staging");
        assert_eq!((c.skew_seconds, c.max_lifetime_seconds, c.max_token_bytes), (30, 60, 4096));
        assert_eq!((c.issuer_url.as_str(), c.site_id.as_str(), c.environment.as_str()), ("https://issuer.example", "site-a", "staging"));
    }

    #[test]
    fn a_good_map_builds_and_derives_the_key_set_address() {
        let c = PlatformSigninConfig::from_env_map(&good()).expect("valid");
        assert_eq!(c.issuer_url, "https://issuer.example");
        assert_eq!(c.jwks_url, "https://issuer.example/.well-known/jwks.json");
        assert_eq!((c.site_id.as_str(), c.environment.as_str()), ("site-a", "production"));
    }

    #[test]
    fn an_explicit_key_set_address_on_the_issuers_host_is_kept() {
        let vars = with(JWKS_URL_VARIABLE, "https://issuer.example/keys/current.json");
        assert_eq!(PlatformSigninConfig::from_env_map(&vars).unwrap().jwks_url, "https://issuer.example/keys/current.json");
    }

    #[test]
    fn a_port_on_the_issuer_is_allowed_and_must_match_on_the_key_set() {
        let mut vars = with(ISSUER_URL_VARIABLE, "https://issuer.example:8443");
        assert!(PlatformSigninConfig::from_env_map(&vars).is_ok());
        vars.insert(JWKS_URL_VARIABLE.into(), "https://issuer.example/k".into());
        assert_eq!(refusal(&vars).problem, ConfigProblem::WrongHostForIssuer);
    }

    #[test]
    fn each_required_variable_missing_is_named() {
        for name in [ISSUER_URL_VARIABLE, SITE_ID_VARIABLE, ENVIRONMENT_VARIABLE] {
            let mut vars = good();
            vars.remove(name);
            let error = refusal(&vars);
            assert_eq!((error.variable, error.problem), (name, ConfigProblem::Missing));
            assert!(error.to_string().starts_with(name));
        }
    }

    #[test]
    fn an_empty_value_counts_as_missing() {
        assert_eq!(refusal(&with(SITE_ID_VARIABLE, "")).problem, ConfigProblem::Missing);
    }

    #[test]
    fn bad_issuer_urls_name_the_issuer_variable() {
        let cases = [
            ("http://issuer.example", ConfigProblem::NotHttps),
            ("issuer.example", ConfigProblem::NotHttps),
            ("HTTPS://issuer.example", ConfigProblem::NotHttps),
            ("https://issuer.example/", ConfigProblem::PathQueryOrFragment),
            ("https://issuer.example/path", ConfigProblem::PathQueryOrFragment),
            ("https://issuer.example?x=1", ConfigProblem::PathQueryOrFragment),
            ("https://issuer.example#frag", ConfigProblem::PathQueryOrFragment),
            ("https://issuer.example\\evil", ConfigProblem::PathQueryOrFragment),
            ("https://user:pw@issuer.example", ConfigProblem::CredentialsInUrl),
            ("https://issuer.example@evil.example", ConfigProblem::CredentialsInUrl),
            ("https://Issuer.example", ConfigProblem::UpperCase),
            ("https://", ConfigProblem::BadHost),
            ("https://issuer .example", ConfigProblem::BadHost),
            ("https://issuer.example:", ConfigProblem::BadHost),
            ("https://issuer.example:0", ConfigProblem::BadHost),
            ("https://issuer.example:99999", ConfigProblem::BadHost),
            ("https://[::1]", ConfigProblem::BadHost),
            ("https://-issuer.example", ConfigProblem::BadHost),
            ("https://issuer..example", ConfigProblem::BadHost),
            ("https://iss\u{fc}er.example", ConfigProblem::BadHost),
            (" https://issuer.example", ConfigProblem::NotHttps),
        ];
        for (value, problem) in cases {
            let error = refusal(&with(ISSUER_URL_VARIABLE, value));
            assert_eq!(error.variable, ISSUER_URL_VARIABLE, "{value:?}");
            assert_eq!(error.problem, problem, "{value:?}");
        }
    }

    #[test]
    fn bad_key_set_urls_name_the_key_set_variable() {
        let cases = [
            ("http://issuer.example/k", ConfigProblem::NotHttps),
            ("https://other.example/k", ConfigProblem::WrongHostForIssuer),
            ("https://issuer.example.evil.example/k", ConfigProblem::WrongHostForIssuer),
            ("https://user@issuer.example/k", ConfigProblem::CredentialsInUrl),
            ("https://issuer.example/k?x=1", ConfigProblem::PathQueryOrFragment),
            ("https://issuer.example/k#f", ConfigProblem::PathQueryOrFragment),
            ("https://issuer.example", ConfigProblem::BadShape),
            ("https://issuer.example/a b", ConfigProblem::BadShape),
        ];
        for (value, problem) in cases {
            let error = refusal(&with(JWKS_URL_VARIABLE, value));
            assert_eq!(error.variable, JWKS_URL_VARIABLE, "{value:?}");
            assert_eq!(error.problem, problem, "{value:?}");
        }
    }

    #[test]
    fn bad_site_references_name_the_site_variable() {
        for value in ["Site-A", "-site", "site_a", "site a", "a/b", &"a".repeat(64), "sité"] {
            let error = refusal(&with(SITE_ID_VARIABLE, value));
            assert_eq!((error.variable, error.problem), (SITE_ID_VARIABLE, ConfigProblem::BadShape), "{value:?}");
        }
        assert!(PlatformSigninConfig::from_env_map(&with(SITE_ID_VARIABLE, &"a".repeat(63))).is_ok());
        assert!(PlatformSigninConfig::from_env_map(&with(SITE_ID_VARIABLE, "0-site")).is_ok());
    }

    #[test]
    fn only_production_and_staging_are_environments() {
        for value in ["Production", "prod", "dev", "production ", "production\n"] {
            let error = refusal(&with(ENVIRONMENT_VARIABLE, value));
            assert_eq!((error.variable, error.problem), (ENVIRONMENT_VARIABLE, ConfigProblem::NotAnEnvironment), "{value:?}");
        }
        assert!(PlatformSigninConfig::from_env_map(&with(ENVIRONMENT_VARIABLE, "staging")).is_ok());
    }

    #[test]
    fn no_error_ever_echoes_the_value() {
        let marker = "very-secret-marker-9137";
        let values = [
            (ISSUER_URL_VARIABLE, format!("http://user:{marker}@{marker}.example/{marker}")),
            (ISSUER_URL_VARIABLE, format!("https://{marker}.example/{marker}")),
            (JWKS_URL_VARIABLE, format!("https://{marker}.example/{marker}?{marker}")),
            (SITE_ID_VARIABLE, format!("Bad {marker}")),
            (ENVIRONMENT_VARIABLE, marker.to_string()),
        ];
        for (name, value) in values {
            let error = refusal(&with(name, &value));
            let shown = format!("{error} {error:?}");
            assert!(!shown.contains(marker), "{name}: {shown}");
            assert!(shown.contains(name));
        }
    }

    #[test]
    fn the_first_problem_found_follows_a_fixed_order() {
        let mut vars = HashMap::new();
        assert_eq!(refusal(&vars).variable, ISSUER_URL_VARIABLE);
        vars.insert(ISSUER_URL_VARIABLE.into(), "https://issuer.example".into());
        assert_eq!(refusal(&vars).variable, SITE_ID_VARIABLE);
        vars.insert(SITE_ID_VARIABLE.into(), "site-a".into());
        assert_eq!(refusal(&vars).variable, ENVIRONMENT_VARIABLE);
    }
}
