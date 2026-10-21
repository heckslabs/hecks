//! The base64 the host reads and writes, in the two alphabets and strictness it needs.
//!
//! Both decoders refuse a second spelling of the same bytes where they can: URL-safe text must be
//! canonical (no padding, no spare non-zero bits), because a signature that verifies over one
//! spelling must not be re-spelled into a lookalike the issuer never produced.

use base64::alphabet;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig, URL_SAFE_NO_PAD};
use base64::engine::DecodePaddingMode;
use base64::Engine;

/// Standard alphabet, accepting padding or none: what webhook secrets and signatures arrive as.
const STANDARD_ANY_PADDING: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

/// Unpadded base64url (RFC 4648 section 5).
pub fn url_encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Canonical unpadded base64url; `None` for padding, a character outside the alphabet, a length
/// no byte string encodes to, or spare trailing bits that are not zero.
pub fn url_decode(text: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(text).ok()
}

/// Standard base64, padded or not; `None` on any other character.
pub fn standard_decode(text: &str) -> Option<Vec<u8>> {
    STANDARD_ANY_PADDING.decode(text).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_text_round_trips_every_length_and_is_url_safe() {
        for input in [
            &b""[..],
            b"a",
            b"ab",
            b"abc",
            b"abcd",
            b"\x00\xff\x10hello world!",
        ] {
            let encoded = url_encode(input);
            assert!(
                !encoded.contains(['+', '/', '=']),
                "must be URL-safe: {encoded}"
            );
            assert_eq!(url_decode(&encoded).as_deref(), Some(input));
        }
    }

    #[test]
    fn url_text_must_be_canonical() {
        assert_eq!(url_decode("Zg").as_deref(), Some(&b"f"[..]));
        assert_eq!(url_decode("Zg=="), None, "padding is a second spelling");
        assert_eq!(url_decode("Zh"), None, "spare bits must be zero");
        assert_eq!(
            url_decode("a+b/"),
            None,
            "the standard alphabet is another spelling"
        );
        assert_eq!(
            url_decode("Z"),
            None,
            "no byte string encodes to one character"
        );
    }

    #[test]
    fn standard_text_decodes_padded_or_not_and_refuses_other_characters() {
        assert_eq!(
            standard_decode("c2VjcmV0LWtleQ==").as_deref(),
            Some(&b"secret-key"[..])
        );
        assert_eq!(
            standard_decode("c2VjcmV0LWtleQ").as_deref(),
            Some(&b"secret-key"[..])
        );
        assert_eq!(
            standard_decode("-_"),
            None,
            "the URL-safe alphabet is not standard"
        );
        assert_eq!(standard_decode("not base64!"), None);
    }
}
