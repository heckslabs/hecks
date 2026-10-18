//! The settings that switch platform sign-in on, read once at boot from an explicit map.
//!
//! The switch is `PLATFORM_SIGNIN`. Unset or empty means the feature does not exist: no extension
//! is installed and the host answers exactly as it did before, whatever other `PLATFORM_*`
//! variables are present, so switching off is one unset. Any other value must be `alongside` or
//! `default`, and then every other setting the flow needs must be present and valid, or the boot
//! is refused. A refusal names the variable and the kind of mistake, never the value, because a
//! mistyped value is often a pasted secret.
//!
//! Nothing here reads the process environment: [`SigninSettings::from_env_map`] takes a map, and
//! [`PROCESS_VARIABLES`] lists the names a caller copies from the process into it.

use std::collections::HashMap;
use std::fmt;

use super::config::{ConfigError, PlatformSigninConfig};

/// The variable that switches the feature on and chooses how.
pub const MODE_VARIABLE: &str = "PLATFORM_SIGNIN";
/// The public address of this site; the callback and the cookie flags derive from it.
pub const SITE_URL_VARIABLE: &str = "SITE_URL";
/// The secret that signs the account cookie.
pub const SESSION_SECRET_VARIABLE: &str = "SESSION_SECRET";
/// The variable that says this process is one long-lived server.
pub const SERVE_MODE_VARIABLE: &str = "HECKS_SERVE_MODE";
/// The variable that names the account cookie.
pub const ACCOUNT_COOKIE_VARIABLE: &str = "HECKS_SESSION_COOKIE";

/// Every variable the settings read, so a caller can copy exactly these from the process.
pub const PROCESS_VARIABLES: [&str; 9] = [
    MODE_VARIABLE,
    super::config::ISSUER_URL_VARIABLE,
    super::config::JWKS_URL_VARIABLE,
    super::config::SITE_ID_VARIABLE,
    super::config::ENVIRONMENT_VARIABLE,
    SITE_URL_VARIABLE,
    SESSION_SECRET_VARIABLE,
    SERVE_MODE_VARIABLE,
    ACCOUNT_COOKIE_VARIABLE,
];

/// How the platform flow sits next to the site's existing Google sign-in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// `GET /auth/platform` starts the platform flow; `/auth/google` is untouched.
    Alongside,
    /// `GET /auth/google` starts the platform flow, `?via=google` keeps the Google one.
    Default,
}

/// Everything the flow needs, validated.
#[derive(Debug, Clone)]
pub struct SigninSettings {
    pub mode: Mode,
    pub config: PlatformSigninConfig,
    /// The site's public address without a trailing slash; always https.
    pub site_url: String,
    pub session_secret: String,
    pub account_cookie: String,
}

/// A refused setting: which variable, and what kind of mistake, never the value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsError {
    /// One of the issuer, key set, site or environment settings.
    Config(ConfigError),
    /// Any other setting.
    Setting {
        variable: &'static str,
        problem: &'static str,
    },
}

impl fmt::Display for SettingsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Config(error) => write!(f, "{error}"),
            Self::Setting { variable, problem } => write!(f, "{variable} {problem}"),
        }
    }
}

impl std::error::Error for SettingsError {}

impl SettingsError {
    /// Returns the name of the variable at fault.
    pub const fn variable(&self) -> &'static str {
        match self {
            Self::Config(error) => error.variable,
            Self::Setting { variable, .. } => variable,
        }
    }
}

impl SigninSettings {
    /// Builds the settings, or `None` when `PLATFORM_SIGNIN` is unset or empty.
    ///
    /// # Errors
    ///
    /// Returns the first setting that is missing or malformed once the switch is on.
    pub fn from_env_map(vars: &HashMap<String, String>) -> Result<Option<Self>, SettingsError> {
        let Some(mode) = read_mode(vars)? else {
            return Ok(None);
        };
        let config = PlatformSigninConfig::from_env_map(vars).map_err(SettingsError::Config)?;
        let site_url = read_site_url(vars)?;
        let session_secret = required(vars, SESSION_SECRET_VARIABLE)?.to_string();
        check_serve_mode(vars)?;
        let account_cookie = read_account_cookie(vars)?;
        Ok(Some(Self {
            mode,
            config,
            site_url,
            session_secret,
            account_cookie,
        }))
    }
}

const fn setting(variable: &'static str, problem: &'static str) -> SettingsError {
    SettingsError::Setting { variable, problem }
}

fn optional<'a>(vars: &'a HashMap<String, String>, name: &str) -> Option<&'a str> {
    vars.get(name)
        .map(String::as_str)
        .filter(|value| !value.is_empty())
}

fn required<'a>(
    vars: &'a HashMap<String, String>,
    name: &'static str,
) -> Result<&'a str, SettingsError> {
    optional(vars, name).ok_or_else(|| setting(name, "is not set"))
}

/// Unset or empty is off; exactly `alongside` or `default` is on; anything else is refused.
fn read_mode(vars: &HashMap<String, String>) -> Result<Option<Mode>, SettingsError> {
    match optional(vars, MODE_VARIABLE) {
        None => Ok(None),
        Some("alongside") => Ok(Some(Mode::Alongside)),
        Some("default") => Ok(Some(Mode::Default)),
        Some(_) => Err(setting(
            MODE_VARIABLE,
            "must be alongside or default, or be left unset",
        )),
    }
}

/// The site address must be a bare https origin; one trailing slash is dropped.
fn read_site_url(vars: &HashMap<String, String>) -> Result<String, SettingsError> {
    let url = required(vars, SITE_URL_VARIABLE)?;
    let origin = url.strip_suffix('/').unwrap_or(url);
    let authority = origin.strip_prefix("https://").unwrap_or("");
    let plain = !authority.is_empty() && !authority.contains(['/', '?', '#', '@', '\\', ' ']);
    if plain {
        Ok(origin.to_string())
    } else {
        Err(setting(
            SITE_URL_VARIABLE,
            "must be a plain https address with no path, query or credentials",
        ))
    }
}

/// The single-use record of token identifiers lives in this process, so it must be the only one.
fn check_serve_mode(vars: &HashMap<String, String>) -> Result<(), SettingsError> {
    match optional(vars, SERVE_MODE_VARIABLE) {
        Some("1") => Ok(()),
        _ => Err(setting(
            SERVE_MODE_VARIABLE,
            "must be 1: platform sign-in needs the single long-lived server",
        )),
    }
}

fn read_account_cookie(vars: &HashMap<String, String>) -> Result<String, SettingsError> {
    crate::auth::resolve_account_cookie(optional(vars, ACCOUNT_COOKIE_VARIABLE))
        .map_err(|_| setting(ACCOUNT_COOKIE_VARIABLE, "is not a valid cookie name"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full() -> HashMap<String, String> {
        [
            ("PLATFORM_SIGNIN", "alongside"),
            ("PLATFORM_ISSUER_URL", "https://issuer.example"),
            ("PLATFORM_SITE_ID", "site-a"),
            ("PLATFORM_ENVIRONMENT", "production"),
            ("SITE_URL", "https://site.example"),
            ("SESSION_SECRET", "a-long-session-secret-for-tests"),
            ("HECKS_SERVE_MODE", "1"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
    }

    fn without(name: &str) -> HashMap<String, String> {
        let mut vars = full();
        vars.remove(name);
        vars
    }

    fn with(name: &str, value: &str) -> HashMap<String, String> {
        let mut vars = full();
        vars.insert(name.to_string(), value.to_string());
        vars
    }

    fn refused(vars: &HashMap<String, String>) -> SettingsError {
        SigninSettings::from_env_map(vars).expect_err("the settings are refused")
    }

    #[test]
    fn an_unset_switch_means_no_feature_even_when_other_variables_are_set() {
        let vars = without("PLATFORM_SIGNIN");
        assert!(SigninSettings::from_env_map(&vars).unwrap().is_none());
        assert!(SigninSettings::from_env_map(&HashMap::new())
            .unwrap()
            .is_none());
    }

    #[test]
    fn an_empty_switch_means_no_feature() {
        assert!(SigninSettings::from_env_map(&with("PLATFORM_SIGNIN", ""))
            .unwrap()
            .is_none());
    }

    #[test]
    fn alongside_and_default_are_the_two_modes() {
        let alongside = SigninSettings::from_env_map(&full()).unwrap().unwrap();
        assert_eq!(alongside.mode, Mode::Alongside);
        let default = SigninSettings::from_env_map(&with("PLATFORM_SIGNIN", "default"))
            .unwrap()
            .unwrap();
        assert_eq!(default.mode, Mode::Default);
    }

    #[test]
    fn any_other_switch_value_refuses_naming_only_the_variable() {
        for bad in [
            "ALONGSIDE",
            "on",
            "off",
            "true",
            "1",
            "Default",
            " alongside",
            "alongside ",
            "both",
        ] {
            let error = refused(&with("PLATFORM_SIGNIN", bad));
            assert_eq!(error.variable(), "PLATFORM_SIGNIN", "{bad:?}");
            assert_eq!(
                error.to_string(),
                "PLATFORM_SIGNIN must be alongside or default, or be left unset",
                "{bad:?}"
            );
        }
    }

    #[test]
    fn each_required_setting_missing_refuses_naming_it() {
        for name in [
            "PLATFORM_ISSUER_URL",
            "PLATFORM_SITE_ID",
            "PLATFORM_ENVIRONMENT",
            "SITE_URL",
            "SESSION_SECRET",
            "HECKS_SERVE_MODE",
        ] {
            let error = refused(&without(name));
            assert_eq!(error.variable(), name);
            assert!(error.to_string().starts_with(name), "{error}");
        }
    }

    #[test]
    fn the_key_set_address_stays_optional() {
        let settings = SigninSettings::from_env_map(&full()).unwrap().unwrap();
        assert_eq!(
            settings.config.jwks_url,
            "https://issuer.example/.well-known/jwks.json"
        );
        let own = with("PLATFORM_JWKS_URL", "https://issuer.example/keys.json");
        assert_eq!(
            SigninSettings::from_env_map(&own)
                .unwrap()
                .unwrap()
                .config
                .jwks_url,
            "https://issuer.example/keys.json"
        );
    }

    #[test]
    fn a_bad_pinned_value_refuses_naming_the_variable_and_never_the_value() {
        let sentinel = "http://leaky-sentinel.example/path?secret=hunter2";
        for name in [
            "PLATFORM_ISSUER_URL",
            "PLATFORM_JWKS_URL",
            "PLATFORM_SITE_ID",
            "PLATFORM_ENVIRONMENT",
            "SITE_URL",
        ] {
            let error = refused(&with(name, sentinel));
            assert_eq!(error.variable(), name);
            let text = error.to_string();
            assert!(
                !text.contains("sentinel") && !text.contains("hunter2"),
                "{name}: {text}"
            );
        }
    }

    #[test]
    fn the_site_address_must_be_a_plain_https_origin() {
        for bad in [
            "http://site.example",
            "site.example",
            "https://site.example/app",
            "https://site.example?x=1",
            "https://user@site.example",
        ] {
            assert_eq!(
                refused(&with("SITE_URL", bad)).variable(),
                "SITE_URL",
                "{bad}"
            );
        }
        let trimmed = SigninSettings::from_env_map(&with("SITE_URL", "https://site.example/"))
            .unwrap()
            .unwrap();
        assert_eq!(trimmed.site_url, "https://site.example");
    }

    #[test]
    fn a_session_secret_is_required_and_never_printed() {
        assert_eq!(
            refused(&with("SESSION_SECRET", "")).variable(),
            "SESSION_SECRET"
        );
        let error = refused(&without("SESSION_SECRET"));
        assert!(!error.to_string().contains("a-long-session-secret"));
    }

    #[test]
    fn the_per_process_jti_record_needs_the_single_server_mode() {
        for bad in ["0", "", "true", "yes"] {
            assert_eq!(
                refused(&with("HECKS_SERVE_MODE", bad)).variable(),
                "HECKS_SERVE_MODE",
                "{bad:?}"
            );
        }
    }

    #[test]
    fn the_account_cookie_name_defaults_and_an_invalid_one_refuses() {
        let default = SigninSettings::from_env_map(&full()).unwrap().unwrap();
        assert_eq!(default.account_cookie, crate::auth::DEFAULT_ACCOUNT_COOKIE);
        let named = SigninSettings::from_env_map(&with("HECKS_SESSION_COOKIE", "site_session"))
            .unwrap()
            .unwrap();
        assert_eq!(named.account_cookie, "site_session");
        assert_eq!(
            refused(&with("HECKS_SESSION_COOKIE", "bad name;")).variable(),
            "HECKS_SESSION_COOKIE"
        );
    }

    #[test]
    fn the_process_variable_list_names_exactly_what_is_read() {
        for name in PROCESS_VARIABLES {
            let vars = without(name);
            let _ = SigninSettings::from_env_map(&vars);
        }
        assert!(PROCESS_VARIABLES.contains(&"PLATFORM_SIGNIN"));
        assert!(PROCESS_VARIABLES.contains(&"SESSION_SECRET"));
    }
}
