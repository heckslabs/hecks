//! The literal scanner both closed checks share: strings, symbols, numbers, regexps, `%w` lists
//! and constant paths, each read whole so a check sees one token, never the characters inside it.
//!
//! A literal is closed when reading it can run nothing: a string or regexp with an interpolation
//! (`#{…}`, `#@x`, `#$x`) is refused here, and so is every percent literal but `%w`, `%i` and
//! `%q`, since the others interpolate or run a shell.

use super::denied;

/// Why a scan refused, and the byte it refused at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub at: usize,
    pub why: String,
}

impl Refusal {
    pub fn new(at: usize, why: impl Into<String>) -> Self {
        Self {
            at,
            why: why.into(),
        }
    }
}

pub type Scan<T> = Result<T, Refusal>;

/// A cursor over one argument list or predicate body.
pub struct Cursor<'a> {
    pub text: &'a str,
    pub at: usize,
}

impl<'a> Cursor<'a> {
    pub const fn new(text: &'a str) -> Self {
        Self { text, at: 0 }
    }

    pub fn rest(&self) -> &'a str {
        &self.text[self.at..]
    }

    pub fn peek(&self) -> Option<char> {
        self.rest().chars().next()
    }

    pub fn peek_at(&self, offset: usize) -> Option<char> {
        self.rest().chars().nth(offset)
    }

    pub fn bump(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.at += ch.len_utf8();
        Some(ch)
    }

    pub fn skip_space(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.bump();
        }
    }

    /// The next character that is not a space, without moving.
    pub fn next_solid(&self) -> Option<char> {
        self.rest().chars().find(|c| !c.is_whitespace())
    }

    pub fn eat(&mut self, prefix: &str) -> bool {
        if self.rest().starts_with(prefix) {
            self.at += prefix.len();
            true
        } else {
            false
        }
    }
}

pub const fn is_word_start(ch: char) -> bool {
    ch.is_ascii_lowercase() || ch == '_'
}

pub const fn is_word_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_'
}

/// Reads `[a-z_]\w*`, plus one trailing `?` or `!` when `suffixed`.
pub fn identifier<'a>(cursor: &mut Cursor<'a>, suffixed: bool) -> &'a str {
    let start = cursor.at;
    while cursor.peek().is_some_and(is_word_char) {
        cursor.bump();
    }
    if suffixed && matches!(cursor.peek(), Some('?' | '!')) && cursor.peek_at(1) != Some('=') {
        cursor.bump();
    }
    &cursor.text[start..cursor.at]
}

/// Reads a quoted string whose opening quote is next; refuses an interpolation in `"…"`.
pub fn string(cursor: &mut Cursor<'_>) -> Scan<()> {
    let start = cursor.at;
    let Some(quote) = cursor.bump() else {
        return Err(Refusal::new(start, "expected a string"));
    };
    let interpolates = quote == '"' || quote == '`';
    if quote == '`' {
        return Err(Refusal::new(start, "a backtick runs a shell command"));
    }
    body_until(cursor, start, quote, quote, interpolates)
}

/// Reads up to and past `close`, nesting on `open` when it differs, refusing an interpolation
/// when the literal interpolates.
fn body_until(
    cursor: &mut Cursor<'_>,
    start: usize,
    open: char,
    close: char,
    interpolates: bool,
) -> Scan<()> {
    let mut depth = 0usize;
    loop {
        let here = cursor.at;
        let Some(ch) = cursor.bump() else {
            return Err(Refusal::new(start, "a literal is never closed"));
        };
        if ch == '\\' {
            cursor.bump();
            continue;
        }
        if interpolates && ch == '#' && matches!(cursor.peek(), Some('{' | '@' | '$')) {
            return Err(Refusal::new(
                here,
                "an interpolation (`#{…}`) runs Ruby; a closed literal spells its text out",
            ));
        }
        if ch == close && depth == 0 {
            return Ok(());
        }
        if open != close {
            if ch == open {
                depth += 1;
            } else if ch == close {
                depth -= 1;
            }
        }
    }
}

/// Reads a `%w[…]`, `%i[…]` or `%q[…]` list or string; refuses every other percent literal.
pub fn percent(cursor: &mut Cursor<'_>) -> Scan<()> {
    let start = cursor.at;
    cursor.bump();
    let kind = cursor.bump();
    let Some(kind @ ('w' | 'i' | 'q')) = kind else {
        return Err(Refusal::new(
            start,
            "only %w, %i and %q percent literals are closed; the others interpolate or run a \
             shell",
        ));
    };
    let Some(open) = cursor.bump() else {
        return Err(Refusal::new(start, "a percent literal is never closed"));
    };
    let close = match open {
        '[' => ']',
        '(' => ')',
        '{' => '}',
        '<' => '>',
        other if other.is_ascii_punctuation() => other,
        _ => {
            return Err(Refusal::new(
                start,
                format!("%{kind} needs a bracket delimiter"),
            ));
        }
    };
    body_until(cursor, start, open, close, false)
}

/// Reads a regexp literal whose `/` is next, and its flags.
pub fn regexp(cursor: &mut Cursor<'_>) -> Scan<()> {
    let start = cursor.at;
    cursor.bump();
    body_until(cursor, start, '/', '/', true)?;
    while cursor.peek().is_some_and(|c| matches!(c, 'i' | 'm' | 'x')) {
        cursor.bump();
    }
    Ok(())
}

/// Reads a number: digits with `_`, an optional fraction and exponent; a leading `-` is the
/// caller's.
pub fn number(cursor: &mut Cursor<'_>) {
    let digits = |cursor: &mut Cursor<'_>| {
        while cursor
            .peek()
            .is_some_and(|c| c.is_ascii_digit() || c == '_')
        {
            cursor.bump();
        }
    };
    digits(cursor);
    if cursor.peek() == Some('.') && cursor.peek_at(1).is_some_and(|c| c.is_ascii_digit()) {
        cursor.bump();
        digits(cursor);
    }
    if matches!(cursor.peek(), Some('e' | 'E'))
        && cursor
            .peek_at(1)
            .is_some_and(|c| c.is_ascii_digit() || c == '-' || c == '+')
    {
        cursor.bump();
        cursor.bump();
        digits(cursor);
    }
}

/// Reads a symbol whose `:` is next: `:name`, `:name?`, `:name=`, `:Name` or `:"…"`.
pub fn symbol(cursor: &mut Cursor<'_>) -> Scan<()> {
    let start = cursor.at;
    cursor.bump();
    match cursor.peek() {
        Some('"' | '\'') => string(cursor),
        Some(ch) if ch.is_ascii_alphabetic() || ch == '_' => {
            identifier(cursor, true);
            if cursor.peek() == Some('=') && !matches!(cursor.peek_at(1), Some('=' | '>' | '~')) {
                cursor.bump();
            }
            Ok(())
        }
        _ => Err(Refusal::new(start, "a symbol is a name after `:`")),
    }
}

/// Reads a constant path (`Name`, `Domain::Name`), refusing one that starts at a host handle.
///
/// Only the first segment can reach Ruby's own top-level constants: `Stall::File` is looked up in
/// `Stall` alone, so it names the domain's `File` and never Ruby's.
pub fn constant_path<'a>(cursor: &mut Cursor<'a>) -> Scan<&'a str> {
    let start = cursor.at;
    loop {
        let segment_start = cursor.at;
        if !cursor.peek().is_some_and(|c| c.is_ascii_uppercase()) {
            return Err(Refusal::new(
                segment_start,
                "`::` reaches a method; a constant path names constants only",
            ));
        }
        while cursor.peek().is_some_and(is_word_char) {
            cursor.bump();
        }
        let segment = &cursor.text[segment_start..cursor.at];
        if segment_start == start && denied::is_host_constant(segment) {
            return Err(Refusal::new(
                segment_start,
                format!("`{segment}` is a handle on the host (its process, files or environment)"),
            ));
        }
        if !cursor.eat("::") {
            return Ok(&cursor.text[start..cursor.at]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan_string(text: &str) -> Scan<()> {
        string(&mut Cursor::new(text))
    }

    #[test]
    fn a_plain_string_is_closed() {
        assert!(scan_string(r#""a \"b\" c""#).is_ok());
        assert!(scan_string("'a #{b}'").is_ok());
    }

    #[test]
    fn an_interpolated_string_is_refused() {
        assert!(scan_string(r#""a #{`id`}""#).is_err());
        assert!(scan_string(r##""#@x""##).is_err());
        assert!(scan_string(r##""#$0""##).is_err());
        assert!(scan_string("`id`").is_err());
    }

    #[test]
    fn an_escaped_hash_is_text() {
        assert!(scan_string(r#""a \#{b}""#).is_ok());
    }

    #[test]
    fn only_quiet_percent_literals_are_closed() {
        assert!(percent(&mut Cursor::new("%w[a b]")).is_ok());
        assert!(percent(&mut Cursor::new("%i(a b)")).is_ok());
        assert!(percent(&mut Cursor::new("%x(id)")).is_err());
        assert!(percent(&mut Cursor::new("%W[#{a}]")).is_err());
    }

    #[test]
    fn a_host_constant_is_refused_in_any_segment() {
        assert!(constant_path(&mut Cursor::new("Pizzas::Order")).is_ok());
        assert!(constant_path(&mut Cursor::new("ENV")).is_err());
        assert!(constant_path(&mut Cursor::new("Stall::File")).is_ok());
        assert!(constant_path(&mut Cursor::new("Foo::bar")).is_err());
    }
}
