//! The closed predicate check: a `given`, `invariant`, `ensures` or `where` body is one
//! expression of the rule language, read as text and never run.
//!
//! The body may name attributes and arguments, walk them with `.` and `&.`, compare, combine and
//! do arithmetic, hold literals and `{ |x| … }` blocks over a list. It may not assign, start a
//! second statement, read a global or instance variable, interpolate, branch with a Ruby keyword,
//! call a method on a constant, or spell a call the rule language never has (`send`, `eval`,
//! `system` …), so the text the gem hands its evaluator is an expression and nothing more.

use super::denied;
use super::scan::{self, Cursor, Refusal, Scan};

/// Checks one predicate body, its lines joined by spaces.
pub fn check(text: &str) -> Scan<()> {
    let mut cursor = Cursor::new(text);
    let mut operand_next = true;
    loop {
        cursor.skip_space();
        let start = cursor.at;
        let Some(ch) = cursor.peek() else {
            return Ok(());
        };
        operand_next = match ch {
            '"' | '\'' | '`' => scan::string(&mut cursor).map(|()| false)?,
            ':' if cursor.peek_at(1) == Some(':') => {
                return Err(Refusal::new(
                    start,
                    "`::` reaches a constant from outside the rule",
                ));
            }
            ':' if operand_next => scan::symbol(&mut cursor).map(|()| false)?,
            '%' if operand_next => scan::percent(&mut cursor).map(|()| false)?,
            '/' if operand_next => scan::regexp(&mut cursor).map(|()| false)?,
            '0'..='9' => {
                scan::number(&mut cursor);
                false
            }
            'A'..='Z' => constant(&mut cursor)?,
            c if scan::is_word_start(c) => name(&mut cursor, start)?,
            '|' if cursor.peek_at(1) != Some('|') => block_parameters(&mut cursor)?,
            '.' if cursor.rest().starts_with("..") => {
                cursor.eat("...");
                cursor.eat("..");
                true
            }
            '.' => {
                cursor.bump();
                method_name(&mut cursor)?;
                false
            }
            '&' if cursor.peek_at(1) == Some('.') => {
                cursor.eat("&.");
                method_name(&mut cursor)?;
                false
            }
            _ => operator(&mut cursor, start, ch)?,
        };
    }
}

fn constant(cursor: &mut Cursor<'_>) -> Scan<bool> {
    let path = scan::constant_path(cursor)?;
    if matches!(cursor.next_solid(), Some('.' | '(')) {
        return Err(Refusal::new(
            cursor.at,
            format!("`{path}` is called here; a rule reads attributes, not constants"),
        ));
    }
    Ok(false)
}

/// A bare name is an attribute, an argument, a block parameter, a literal or `and`/`or`/`not`.
fn name(cursor: &mut Cursor<'_>, start: usize) -> Scan<bool> {
    let word = scan::identifier(cursor, true);
    if matches!(word, "and" | "or" | "not") {
        return Ok(true);
    }
    if matches!(word, "do" | "end") {
        return Ok(word == "do");
    }
    if denied::RUBY_KEYWORDS.contains(&word) {
        return Err(Refusal::new(
            start,
            format!("`{word}` is Ruby control flow; a rule is one expression"),
        ));
    }
    refuse_call(cursor, word, start)?;
    Ok(false)
}

fn method_name(cursor: &mut Cursor<'_>) -> Scan<()> {
    let start = cursor.at;
    if !cursor
        .peek()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
    {
        return Err(Refusal::new(start, "a `.` is followed by a method name"));
    }
    let word = scan::identifier(cursor, true);
    refuse_call(cursor, word, start)
}

/// Refuses a name the rule language never calls when it is written as a call: followed by
/// `(`, a block, or an argument, as in `send :system`.
fn refuse_call(cursor: &Cursor<'_>, word: &str, at: usize) -> Scan<()> {
    let rest = cursor.rest();
    let after = rest.trim_start();
    let spaced = after.len() < rest.len();
    let called = after.starts_with('(')
        || after.starts_with('{')
        || after.starts_with("do ")
        || (spaced
            && after.chars().next().is_some_and(|c| {
                c.is_ascii_alphanumeric() || matches!(c, '"' | '\'' | '_' | '[' | '%' | '`')
            })
            && !after.starts_with("and ")
            && !after.starts_with("or "))
        || (spaced && after.starts_with(':') && !after.starts_with(": "));
    if called && denied::PREDICATE_CALLS.contains(&word) {
        return Err(Refusal::new(
            at,
            format!("`{word}` is Ruby, not a rule: the rule language has no such call"),
        ));
    }
    Ok(())
}

/// `|item|` or `|key, value|` opening a block over a list: names and commas only.
fn block_parameters(cursor: &mut Cursor<'_>) -> Scan<bool> {
    let start = cursor.at;
    cursor.bump();
    loop {
        cursor.skip_space();
        match cursor.peek() {
            Some('|') => {
                cursor.bump();
                return Ok(true);
            }
            Some(',') => {
                cursor.bump();
            }
            Some(c) if scan::is_word_start(c) => {
                scan::identifier(cursor, false);
            }
            _ => return Err(Refusal::new(start, "block parameters are plain names")),
        }
    }
}

/// The operators a rule combines values with; `true` when an operand comes next.
const OPERATORS: &[&str] = &[
    "===", "==", "!=", "=~", "!~", "<=>", "<=", ">=", "&&", "||", "**", "=>", "<", ">", "!", "+",
    "-", "*", "/", "%", "?", ":", "(", "[", "{", ",",
];

/// Closers end an operand, so what follows is an operator.
const CLOSERS: &[&str] = &[")", "]", "}"];

fn operator(cursor: &mut Cursor<'_>, start: usize, ch: char) -> Scan<bool> {
    if cursor.rest().starts_with("->") {
        return Err(Refusal::new(
            start,
            "`->` makes a lambda; a rule is an expression",
        ));
    }
    if cursor.rest().starts_with("<<") {
        return Err(Refusal::new(start, "`<<` appends or opens a heredoc"));
    }
    if let Some(op) = OPERATORS.iter().find(|op| cursor.rest().starts_with(**op)) {
        if *op == "=>" {
            return Err(Refusal::new(
                start,
                "`=>` matches a pattern or binds a name",
            ));
        }
        cursor.eat(op);
        return Ok(true);
    }
    if let Some(op) = CLOSERS.iter().find(|op| cursor.rest().starts_with(**op)) {
        cursor.eat(op);
        return Ok(false);
    }
    let why = match ch {
        '=' => "`=` assigns; a rule compares with `==`",
        ';' => "`;` starts a second statement; a rule is one expression",
        '$' => "`$` reads a global variable",
        '@' => "`@` reads an instance variable",
        '&' => "`&` passes a block or a method",
        '\\' => "`\\` escapes outside a string",
        '#' => "`#` outside a string",
        _ => "this character is not part of the rule language",
    };
    Err(Refusal::new(start, why))
}

#[cfg(test)]
mod tests {
    use super::check;

    fn closed(text: &str) -> bool {
        check(text).is_ok()
    }

    #[test]
    fn rule_expressions_are_closed() {
        for text in [
            "quantity > 0",
            r#"status == "open" && !archived"#,
            "items.size >= 1 || note.nil?",
            "items.all? { |item| item.qty > 0 }",
            "%w[a b].include?(kind)",
            "owner&.name != :none and total * 2 <= limit",
            "(a + b) % 3 == 0 ? true : false",
            "started_at.nil? || ended_at.nil? || started_at <= ended_at",
            r"code =~ /\A[A-Z]{3}\z/",
            "kind == Kinds::Open",
            r#"load.value != "above" && open.value.to_s.empty?"#,
            "items.any? do |item| item.ok end",
        ] {
            assert!(closed(text), "{text}");
        }
    }

    #[test]
    fn every_way_out_of_an_expression_is_refused() {
        for text in [
            r#"ENV["HOME"]"#,
            r#"File.read("/etc/passwd")"#,
            r#"Kernel.system("id")"#,
            r#"send(:system, "id")"#,
            r#"eval("1")"#,
            "`id`",
            r##""#{`id`}" == x"##,
            r#"instance_eval("1")"#,
            "$stdout",
            "@x",
            "x.then { exit }",
            "x = 1",
            "x += 1",
            "a; b",
            "if a then b end",
            "x.public_send(:y)",
            "::Foo",
            "Foo::bar",
            "-> { 1 }",
            "x.method(:y)",
            "Time.now > x",
        ] {
            assert!(!closed(text), "{text}");
        }
    }
}
