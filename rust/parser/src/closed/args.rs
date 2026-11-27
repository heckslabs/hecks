//! The closed argument check: the text after a word is a list of literals, nothing else.
//!
//! An argument is a string, a symbol, a number, `true`, `false`, `nil`, a regexp, a `%w`/`%i`
//! list, a constant path, an array or hash of those, a `key:` label or `=>` pair, a range of
//! literals, or a `Type` word's call (`list_of(String)`). An identifier anywhere else is a method
//! call and is refused, as is every operator, sigil, statement separator and modifier, so an
//! argument list never calls, assigns, reads a variable or branches.

use super::denied;
use super::scan::{self, Cursor, Refusal, Scan};
use crate::keywords;

/// What an argument list may hold besides literals.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Literals only.
    Literals,
    /// Literals, plus the arithmetic a command's `sets` reads its source from: the command's own
    /// argument and field names, `.field` reads through them, `state(:field)`, `+ - * /` and
    /// grouping. Ruby resolves each name through `CommandBuilder::Operands#method_missing`, so a
    /// name that is a method on every object is refused here, before Ruby could run it.
    Operands,
}

/// Checks one argument list as the lexer split it off its word.
pub fn check(text: &str, mode: Mode) -> Scan<()> {
    let mut cursor = Cursor::new(text);
    let mut parens = 0usize;
    let mut operand_next = true;
    loop {
        cursor.skip_space();
        let start = cursor.at;
        let Some(ch) = cursor.peek() else {
            return if parens == 0 {
                Ok(())
            } else {
                Err(Refusal::new(start, "a `(` is never closed"))
            };
        };
        let arithmetic = mode == Mode::Operands && !operand_next;
        operand_next = match ch {
            '"' | '\'' | '`' => label_after(&mut cursor, scan::string).map(|()| false)?,
            ':' if cursor.peek_at(1) == Some(':') => {
                return Err(Refusal::new(
                    start,
                    "a leading `::` reaches outside the file",
                ));
            }
            ':' => scan::symbol(&mut cursor).map(|()| false)?,
            '-' if cursor.peek_at(1) == Some('>') => {
                return Err(Refusal::new(
                    start,
                    "`->` makes a lambda; an argument is a literal",
                ));
            }
            '%' if !arithmetic => scan::percent(&mut cursor).map(|()| false)?,
            '/' if !arithmetic => scan::regexp(&mut cursor).map(|()| false)?,
            '+' | '-' | '*' | '/' if arithmetic => {
                cursor.bump();
                true
            }
            '-' if cursor.peek_at(1).is_some_and(|c| c.is_ascii_digit()) => {
                cursor.bump();
                scan::number(&mut cursor);
                false
            }
            '0'..='9' => {
                scan::number(&mut cursor);
                false
            }
            'A'..='Z' => constant(&mut cursor)?,
            c if scan::is_word_start(c) => word(&mut cursor, &mut parens, mode)?,
            '(' if mode == Mode::Operands => {
                cursor.bump();
                parens += 1;
                true
            }
            ')' if parens > 0 => {
                cursor.bump();
                parens -= 1;
                refuse_a_call_on(&cursor, "a grouped value")?;
                false
            }
            ',' | '[' | '{' => {
                cursor.bump();
                true
            }
            '}' => {
                cursor.bump();
                false
            }
            ']' => {
                cursor.bump();
                refuse_a_call_on(&cursor, "a list")?;
                false
            }
            '=' if cursor.peek_at(1) == Some('>') => {
                cursor.bump();
                cursor.bump();
                true
            }
            '.' if cursor.rest().starts_with("..") => {
                cursor.eat("...");
                cursor.eat("..");
                true
            }
            _ => return Err(refuse_punctuation(start, ch)),
        };
    }
}

/// A string can be a `"key":` label; either way nothing may be called on it.
fn label_after(cursor: &mut Cursor<'_>, read: fn(&mut Cursor<'_>) -> Scan<()>) -> Scan<()> {
    read(cursor)?;
    if cursor.peek() == Some(':') && cursor.peek_at(1) != Some(':') {
        cursor.bump();
        return Ok(());
    }
    refuse_a_call_on(cursor, "a string")
}

/// A constant names a type; `Name:` is a label. `true` when an operand comes next.
fn constant(cursor: &mut Cursor<'_>) -> Scan<bool> {
    let path = scan::constant_path(cursor)?;
    if cursor.peek() == Some(':') && cursor.peek_at(1) != Some(':') {
        cursor.bump();
        return Ok(true);
    }
    match cursor.next_solid() {
        Some('(' | '[' | '{') => Err(Refusal::new(
            cursor.at,
            format!("`{path}` is called here; a constant argument only names a type"),
        )),
        _ => refuse_a_call_on(cursor, "a constant").map(|()| false),
    }
}

/// A lowercase word is a `key:` label, `true`/`false`/`nil`, a `Type` word's call or, where the
/// mode reads operands, an operand; nothing else, since anywhere else Ruby would call it. `true`
/// when an operand comes next.
fn word(cursor: &mut Cursor<'_>, parens: &mut usize, mode: Mode) -> Scan<bool> {
    let start = cursor.at;
    let name = scan::identifier(cursor, true);
    if cursor.peek() == Some(':') && cursor.peek_at(1) != Some(':') && !name.ends_with('?') {
        cursor.bump();
        return Ok(true);
    }
    if matches!(name, "true" | "false" | "nil") {
        return refuse_a_call_on(cursor, "a literal").map(|()| false);
    }
    let reads_state = mode == Mode::Operands && name == "state";
    if cursor.peek() == Some('(') && (is_type_word(name) || reads_state) {
        cursor.bump();
        *parens += 1;
        return Ok(true);
    }
    if denied::RUBY_KEYWORDS.contains(&name) || matches!(name, "and" | "or" | "not") {
        return Err(Refusal::new(
            start,
            format!("`{name}` is Ruby control flow; an argument list holds literals only"),
        ));
    }
    if mode == Mode::Operands {
        return operand(cursor, name, start).map(|()| false);
    }
    Err(Refusal::new(
        start,
        format!("`{name}` would be called as Ruby; an argument is a literal, not an expression"),
    ))
}

/// An operand name and the `.field` reads after it; none may be a method Ruby defines on every
/// object, nor be called with arguments.
fn operand(cursor: &mut Cursor<'_>, name: &str, start: usize) -> Scan<()> {
    let mut segment = (name, start);
    loop {
        if denied::is_ruby_method(segment.0) || segment.0.ends_with(['?', '!']) {
            return Err(Refusal::new(
                segment.1,
                format!(
                    "`{}` is a Ruby method, not an operand — Ruby would run it",
                    segment.0
                ),
            ));
        }
        if !(cursor.peek() == Some('.') && cursor.peek_at(1).is_some_and(scan::is_word_start)) {
            break;
        }
        cursor.bump();
        let at = cursor.at;
        segment = (scan::identifier(cursor, true), at);
    }
    if matches!(cursor.peek(), Some('(' | '{')) || cursor.rest().starts_with("&.") {
        return Err(Refusal::new(
            cursor.at,
            format!("`{name}` is called here; an operand is read, never called"),
        ));
    }
    Ok(())
}

fn is_type_word(name: &str) -> bool {
    keywords::KEYWORDS
        .iter()
        .any(|k| k.live() && k.context == "Type" && k.word == name)
}

/// Refuses a `.`, `&.` or `::` straight after a literal, since it calls a method on it.
fn refuse_a_call_on(cursor: &Cursor<'_>, what: &str) -> Scan<()> {
    let rest = cursor.rest().trim_start();
    let calls = (rest.starts_with('.') && !rest.starts_with(".."))
        || rest.starts_with("&.")
        || rest.starts_with("::");
    if calls {
        let at = cursor.at + (cursor.rest().len() - rest.len());
        return Err(Refusal::new(
            at,
            format!("a method is called on {what}; an argument is a literal, not an expression"),
        ));
    }
    Ok(())
}

fn refuse_punctuation(at: usize, ch: char) -> Refusal {
    let why = match ch {
        ';' => "`;` starts a second statement; a line holds one word call".to_string(),
        '$' => "`$` reads a global variable".to_string(),
        '@' => "`@` reads an instance variable".to_string(),
        '&' => "`&` passes a block".to_string(),
        '*' => "`*` splats an expression".to_string(),
        '(' => "a bare `(` groups an expression; an argument is a literal".to_string(),
        '=' => "`=` assigns".to_string(),
        '?' => "`?` branches or spells a character literal".to_string(),
        '|' => "`|` opens block parameters".to_string(),
        '\\' => "`\\` escapes outside a string".to_string(),
        '<' => "`<<` opens a heredoc or appends".to_string(),
        other => format!("`{other}` is an operator; an argument list holds literals only"),
    };
    Refusal::new(at, why)
}

#[cfg(test)]
mod tests {
    use super::{check, Mode};

    fn closed(text: &str) -> bool {
        check(text, Mode::Literals).is_ok()
    }

    fn arithmetic(text: &str) -> bool {
        check(text, Mode::Operands).is_ok()
    }

    #[test]
    fn a_sets_source_may_be_arithmetic_over_operands() {
        for text in [
            ":due_at, to: now + 259200",
            ":refund, to: paid * rate / 100",
            ":wattage, to: (wattage * 2) + 1",
            ":current, to: current.value + 1",
            ":positions, append: { ply: state(:ply), pieces: state(:pieces) }",
        ] {
            assert!(arithmetic(text), "{text}");
            assert!(!closed(text), "{text}");
        }
    }

    #[test]
    fn an_operand_that_is_a_ruby_method_is_refused() {
        for text in [
            ":x, to: system",
            ":x, to: rand * 2",
            ":x, to: paid.send",
            ":x, to: paid.freeze",
            ":x, to: paid(1)",
            ":x, to: exit!",
            ":x, to: paid.empty?",
        ] {
            assert!(!arithmetic(text), "{text}");
        }
    }

    #[test]
    fn literals_and_their_containers_are_closed() {
        for text in [
            r#""Order", version: "1.0""#,
            ":name, String, default: 0, optional: true",
            r#":items, list_of(Pizzas::Topping), from: %w[a b], one_of: ["x", "y"]"#,
            r#""Purchase" => "sold", "to" => :done"#,
            r"pattern: /\A[a-z]+\z/i, range: 1..5, rate: -0.5, big: 1_000",
            r#"{ "k" => nil, k2: [1, 2] }, "say": 'it'"#,
        ] {
            assert!(closed(text), "{text}");
        }
    }

    #[test]
    fn every_way_out_of_a_literal_is_refused() {
        for text in [
            "Object.const_get(:String)",
            ":z, ENV",
            r##"default: "#{`id`}""##,
            r#""a" if system("id")"#,
            r#""a"; system("id")"#,
            "default: ENV.fetch(:x)",
            "default: rand",
            "default: $0",
            "default: @x",
            "default: -> { 1 }",
            "default: lambda { 1 }",
            r#"default: "x".freeze"#,
            "default: %x(id)",
            "*names",
            "&:upcase",
            "default: (system 'id')",
            "default: [1].map",
            "default: File",
            "default: ::File",
            "default: Kernel",
            "default: String(1)",
            "x = 1",
            "default: 1 + 1",
            "default: ::Foo",
            "default: Foo::bar",
            r#""a" rescue system("id")"#,
            r#""a" and system("id")"#,
        ] {
            assert!(!closed(text), "{text}");
        }
    }
}
