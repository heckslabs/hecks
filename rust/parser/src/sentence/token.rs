//! Splits one sentence into the words, punctuation and quoted text the phrase matcher reads.

/// What a token is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Word,
    Punct(char),
    Quoted,
}

/// One word, mark or quoted run of a sentence, and where it stood.
#[derive(Debug, Clone)]
pub struct Token {
    pub kind: Kind,
    /// The word as written, the punctuation mark, or the text between the quotes.
    pub text: String,
    /// Byte offsets in the sentence: start inclusive, end exclusive.
    pub start: usize,
    pub end: usize,
}

impl Token {
    /// Whether the token is a plain word, not punctuation or a quoted run.
    pub fn is_word(&self) -> bool {
        self.kind == Kind::Word
    }
}

/// The sentence cut into tokens: `,` and `:` stand alone, a quoted run is one token, and
/// everything else between spaces is a word.
///
/// An unterminated quote answers the byte offset it opened at.
pub fn tokenize(sentence: &str) -> Result<Vec<Token>, usize> {
    let mut tokens = Vec::new();
    let mut chars = sentence.char_indices().peekable();
    while let Some(&(start, c)) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
        } else if c == ',' || c == ':' {
            chars.next();
            tokens.push(Token {
                kind: Kind::Punct(c),
                text: c.to_string(),
                start,
                end: start + 1,
            });
        } else if c == '"' {
            chars.next();
            let mut text = String::new();
            let mut closed_at = None;
            for (at, inner) in chars.by_ref() {
                if inner == '"' {
                    closed_at = Some(at + 1);
                    break;
                }
                text.push(inner);
            }
            let Some(end) = closed_at else { return Err(start) };
            tokens.push(Token {
                kind: Kind::Quoted,
                text,
                start,
                end,
            });
        } else {
            let mut end = start;
            while let Some(&(at, inner)) = chars.peek() {
                if inner.is_whitespace() || inner == ',' || inner == ':' || inner == '"' {
                    break;
                }
                end = at + inner.len_utf8();
                chars.next();
            }
            tokens.push(Token {
                kind: Kind::Word,
                text: sentence[start..end].to_string(),
                start,
                end,
            });
        }
    }
    Ok(tokens)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_words_punctuation_and_quotes() {
        let tokens = tokenize(r#"Rule "a page has a slug", holds: now"#).unwrap_or_default();
        let texts: Vec<&str> = tokens.iter().map(|t| t.text.as_str()).collect();
        assert_eq!(texts, ["Rule", "a page has a slug", ",", "holds", ":", "now"]);
        assert_eq!(tokens[1].kind, Kind::Quoted);
    }

    #[test]
    fn reports_where_an_unterminated_quote_opened() {
        assert_eq!(tokenize(r#"Goal "never closed"#).err(), Some(5));
    }
}
