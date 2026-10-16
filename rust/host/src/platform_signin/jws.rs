//! A compact JWS taken apart without trusting any of it.
//!
//! Exactly three dot-separated segments, each canonical unpadded base64url, the first two JSON
//! objects with no repeated key. Nothing here checks a signature or a claim: a [`CompactJws`] only
//! says the text was structurally a JWS.
//!
//! ## Why the base64url is strict
//!
//! Standard decoders accept padding, the other alphabet, whitespace and spare trailing bits. Each
//! gives a second spelling of the same bytes, and a signature that verifies over one spelling must
//! not be re-spelled into a lookalike the issuer would never have produced. So a segment is accepted
//! only if re-encoding the bytes it decodes to gives back exactly the segment.

use super::strict_json::{self, JsonObject};

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Encodes bytes as unpadded base64url (RFC 4648 section 5).
pub fn encode_base64url(bytes: &[u8]) -> String {
    let _ = (bytes, ALPHABET);
    todo!("encode_base64url")
}

/// Decodes canonical unpadded base64url.
///
/// Returns `None` for padding, any character outside the URL-safe alphabet, a length that no byte
/// string encodes to, and spare trailing bits that are not zero.
pub fn decode_base64url(text: &str) -> Option<Vec<u8>> {
    let _ = text;
    todo!("decode_base64url")
}

/// Why a token text was refused before any claim was read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JwsFault {
    /// Longer than the cap; refused without being parsed.
    TooLarge,
    /// Not structurally a JWS.
    Malformed,
}

/// A structurally valid compact JWS: the two JSON parts and the signed text.
pub struct CompactJws {
    pub header: JsonObject,
    pub claims: JsonObject,
    pub signing_input: String,
    pub signature_segment: String,
}

impl CompactJws {
    /// Parses a token text into its parts.
    ///
    /// # Errors
    ///
    /// Returns [`JwsFault::TooLarge`] when `text` is longer than `max_bytes`, checked before
    /// anything else, and [`JwsFault::Malformed`] when it does not have exactly three segments,
    /// when either of the first two is not canonical base64url of a JSON object, or when that
    /// object repeats a key.
    pub fn parse(text: &str, max_bytes: usize) -> Result<Self, JwsFault> {
        let _ = (text, max_bytes, strict_json::MAX_DEPTH);
        todo!("CompactJws::parse")
    }

    /// Returns the raw signature bytes, or `None` when the segment is not canonical base64url.
    pub fn signature_bytes(&self) -> Option<Vec<u8>> {
        decode_base64url(&self.signature_segment)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(text: &str) -> String {
        encode_base64url(text.as_bytes())
    }

    fn token(header: &str, claims: &str, signature: &str) -> String {
        format!("{}.{}.{}", seg(header), seg(claims), signature)
    }

    #[test]
    fn base64url_round_trips_every_length_and_matches_known_encodings() {
        assert_eq!(encode_base64url(b""), "");
        assert_eq!(encode_base64url(b"f"), "Zg");
        assert_eq!(encode_base64url(b"fo"), "Zm8");
        assert_eq!(encode_base64url(b"foo"), "Zm9v");
        assert_eq!(encode_base64url(&[0xfb, 0xff, 0xfe]), "-__-");
        for len in 0..40usize {
            let bytes: Vec<u8> = (0..len).map(|i| (i * 37 + 11) as u8).collect();
            assert_eq!(decode_base64url(&encode_base64url(&bytes)), Some(bytes));
        }
    }

    #[test]
    fn base64url_refuses_every_second_spelling() {
        for text in ["Zg==", "Zg=", "Zm9v+", "Zm9v/", "Zm 9v", "Zm9v\n", "Zm9", "A", "Zm9vY", "ZB", "Zh", "Zm9\u{e9}", "Zm9v\u{0}"] {
            assert_eq!(decode_base64url(text), None, "{text:?}");
        }
        assert_eq!(decode_base64url("Zg"), Some(b"f".to_vec()));
        assert_eq!(decode_base64url("Zm8"), Some(b"fo".to_vec()));
    }

    #[test]
    fn a_three_segment_token_of_two_objects_parses() {
        let text = token(r#"{"alg":"EdDSA"}"#, r#"{"a":1}"#, "c2ln");
        let jws = CompactJws::parse(&text, 4096).ok().expect("parses");
        assert_eq!(jws.header.get_str("alg"), Some("EdDSA"));
        assert_eq!(jws.signature_segment, "c2ln");
        assert_eq!(jws.signing_input, text.rsplit_once('.').unwrap().0);
        assert_eq!(jws.signature_bytes(), Some(b"sig".to_vec()));
    }

    #[test]
    fn the_wrong_number_of_segments_is_malformed() {
        let two = format!("{}.{}", seg("{}"), seg("{}"));
        let four = format!("{}.{}.c2ln.c2ln", seg("{}"), seg("{}"));
        for text in ["", ".", "..", "...", "a", "a.b", two.as_str(), four.as_str()] {
            assert_eq!(CompactJws::parse(text, 4096).err(), Some(JwsFault::Malformed), "{text:?}");
        }
    }

    #[test]
    fn non_canonical_non_json_and_non_object_parts_are_malformed() {
        let ok = seg("{}");
        let cases = [
            format!("{}=.{ok}.c2ln", seg("{}")),
            format!("{ok}.{}+.c2ln", seg("{}")),
            format!("{}.{ok}.c2ln", seg("[]")),
            format!("{ok}.{}.c2ln", seg("\"s\"")),
            format!("{}.{ok}.c2ln", seg("not json")),
            format!("{ok}.{}.c2ln", seg(r#"{"a":1,"a":2}"#)),
            format!("{}.{ok}.c2ln", seg(r#"{"a":1,"a":1}"#)),
            format!("{ok}..c2ln"),
            format!(".{ok}.c2ln"),
        ];
        for text in cases {
            assert_eq!(CompactJws::parse(&text, 4096).err(), Some(JwsFault::Malformed), "{text:?}");
        }
    }

    #[test]
    fn a_non_canonical_signature_still_parses_but_has_no_bytes() {
        let text = token("{}", "{}", "Zh");
        let jws = CompactJws::parse(&text, 4096).ok().expect("the structure is fine");
        assert_eq!(jws.signature_bytes(), None);
    }

    #[test]
    fn the_size_cap_is_inclusive_and_checked_before_parsing() {
        let text = token("{}", "{}", "c2ln");
        assert!(CompactJws::parse(&text, text.len()).is_ok());
        assert_eq!(CompactJws::parse(&text, text.len() - 1).err(), Some(JwsFault::TooLarge));
        let garbage = "x".repeat(5000);
        assert_eq!(CompactJws::parse(&garbage, 4096).err(), Some(JwsFault::TooLarge));
    }

    #[test]
    fn the_cap_counts_bytes_not_characters() {
        let text = "\u{e9}".repeat(10);
        assert_eq!(text.chars().count(), 10);
        assert_eq!(CompactJws::parse(&text, 15).err(), Some(JwsFault::TooLarge));
    }
}
