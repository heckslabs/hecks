//! The callback's query string, read strictly.
//!
//! The host's general query parser keeps the last of a repeated key. For a sign-in callback that
//! would let two parsers disagree about which `token` or `state` counts, so this one keeps every
//! value and refuses a repeat. Everything except `token` and `state` is ignored: nothing in the
//! query can steer where the browser goes next.

/// The longest query string read, in bytes. It only bounds the work done on hostile input; the
/// verifier caps the token itself.
pub const MAX_QUERY_BYTES: usize = 16 * 1024;

/// The two values a callback carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CallbackParams {
    pub token: String,
    pub state: String,
}

/// Why the query could not be used.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamFault {
    /// The query is longer than [`MAX_QUERY_BYTES`].
    Oversized,
    /// A percent escape is malformed or the decoded text is not UTF-8.
    BadEncoding,
    /// A required parameter was not given.
    Missing,
    /// A required parameter was given more than once.
    Repeated,
}

/// Reads `token` and `state` from a raw query string.
///
/// # Errors
///
/// Returns the [`ParamFault`] that says why the pair is not usable.
pub fn parse_callback(raw_query: &str) -> Result<CallbackParams, ParamFault> {
    let pairs = decode_pairs(raw_query)?;
    Ok(CallbackParams {
        token: single(&pairs, "token")?,
        state: single(&pairs, "state")?,
    })
}

fn single(pairs: &[(String, String)], name: &str) -> Result<String, ParamFault> {
    let mut found = pairs
        .iter()
        .filter(|(key, _)| key == name)
        .map(|(_, value)| value);
    let value = found.next().ok_or(ParamFault::Missing)?;
    if found.next().is_some() {
        return Err(ParamFault::Repeated);
    }
    Ok(value.clone())
}

fn decode_pairs(raw_query: &str) -> Result<Vec<(String, String)>, ParamFault> {
    if raw_query.len() > MAX_QUERY_BYTES {
        return Err(ParamFault::Oversized);
    }
    raw_query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
            Ok((decode(name)?, decode(value)?))
        })
        .collect()
}

/// Decodes percent escapes; a plus stays a plus, as it does in the host's other query reading.
fn decode(text: &str) -> Result<String, ParamFault> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let pair = bytes.get(i + 1..i + 3).ok_or(ParamFault::BadEncoding)?;
            out.push(hex_byte(pair).ok_or(ParamFault::BadEncoding)?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| ParamFault::BadEncoding)
}

fn hex_byte(pair: &[u8]) -> Option<u8> {
    let digit = |b: u8| (b as char).to_digit(16);
    Some((digit(pair[0])? * 16 + digit(pair[1])?) as u8)
}

/// Tells whether the query carries `name` with exactly `value` at least once.
///
/// A malformed query carries nothing.
pub fn has_value(raw_query: &str, name: &str, value: &str) -> bool {
    decode_pairs(raw_query).is_ok_and(|pairs| pairs.iter().any(|(k, v)| k == name && v == value))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_and_state_are_read_and_the_rest_is_ignored() {
        let params =
            parse_callback("token=a.b.c&state=S1&return=https%3A%2F%2Fevil.example&next=/x")
                .unwrap();
        assert_eq!(
            params,
            CallbackParams {
                token: "a.b.c".into(),
                state: "S1".into()
            }
        );
    }

    #[test]
    fn order_and_empty_pairs_do_not_matter() {
        let params = parse_callback("&state=S1&&token=T&").unwrap();
        assert_eq!((params.token.as_str(), params.state.as_str()), ("T", "S1"));
    }

    #[test]
    fn percent_escapes_decode_and_a_plus_stays_a_plus() {
        let params = parse_callback("token=a%2Bb+c&state=%53%31").unwrap();
        assert_eq!(params.token, "a+b+c");
        assert_eq!(params.state, "S1");
    }

    #[test]
    fn a_missing_parameter_is_a_fault_whichever_one() {
        assert_eq!(parse_callback("state=S1"), Err(ParamFault::Missing));
        assert_eq!(parse_callback("token=T"), Err(ParamFault::Missing));
        assert_eq!(parse_callback(""), Err(ParamFault::Missing));
    }

    #[test]
    fn an_empty_value_is_present_and_left_to_the_verifier() {
        let params = parse_callback("token=&state=").unwrap();
        assert_eq!((params.token.as_str(), params.state.as_str()), ("", ""));
    }

    #[test]
    fn a_repeated_parameter_is_refused_even_when_the_values_agree() {
        assert_eq!(
            parse_callback("token=T&token=T&state=S"),
            Err(ParamFault::Repeated)
        );
        assert_eq!(
            parse_callback("token=T&state=S&state=S"),
            Err(ParamFault::Repeated)
        );
        assert_eq!(
            parse_callback("token=T&state=S&token=U"),
            Err(ParamFault::Repeated)
        );
    }

    #[test]
    fn array_style_names_are_different_names() {
        assert_eq!(
            parse_callback("token[]=T&state=S"),
            Err(ParamFault::Missing)
        );
        let params = parse_callback("token=T&state=S&token[]=U").unwrap();
        assert_eq!(params.token, "T");
    }

    #[test]
    fn a_percent_encoded_name_counts_as_the_name() {
        assert_eq!(
            parse_callback("tok%65n=T&token=U&state=S"),
            Err(ParamFault::Repeated)
        );
    }

    #[test]
    fn an_oversized_query_is_refused_before_it_is_read() {
        let big = format!("token={}&state=S", "a".repeat(MAX_QUERY_BYTES));
        assert_eq!(parse_callback(&big), Err(ParamFault::Oversized));
        let exact = format!(
            "token={}&state=S",
            "a".repeat(MAX_QUERY_BYTES - "token=&state=S".len())
        );
        assert_eq!(exact.len(), MAX_QUERY_BYTES);
        assert!(parse_callback(&exact).is_ok());
    }

    #[test]
    fn a_bad_percent_escape_or_invalid_utf8_is_a_fault() {
        for bad in [
            "token=%&state=S",
            "token=%G1&state=S",
            "token=%4&state=S",
            "token=%ff%fe&state=S",
            "token=T&state=%c3",
        ] {
            assert_eq!(parse_callback(bad), Err(ParamFault::BadEncoding), "{bad}");
        }
    }

    #[test]
    fn a_name_without_an_equals_sign_is_a_name_with_an_empty_value() {
        assert_eq!(parse_callback("token&state=S").unwrap().token, "");
    }

    #[test]
    fn has_value_finds_an_exact_pair_anywhere() {
        assert!(has_value("via=google", "via", "google"));
        assert!(has_value("a=1&via=google&b=2", "via", "google"));
        assert!(has_value("via=x&via=google", "via", "google"));
        assert!(has_value("v%69a=goo%67le", "via", "google"));
    }

    #[test]
    fn has_value_is_exact_and_tolerates_junk() {
        for query in [
            "",
            "via=",
            "via=Google",
            "via=google2",
            "via=googl",
            "xvia=google",
            "via",
            "via=%",
            "a=via=google",
        ] {
            assert!(!has_value(query, "via", "google"), "{query:?}");
        }
    }
}
