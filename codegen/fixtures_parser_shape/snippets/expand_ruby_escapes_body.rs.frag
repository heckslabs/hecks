    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('\\') => out.push('\\'),
                Some('"')  => out.push('"'),
                Some('\'') => out.push('\''),
                Some('n')  => out.push('\n'),
                Some('t')  => out.push('\t'),
                Some('r')  => out.push('\r'),
                Some('a')  => out.push('\x07'),
                Some('b')  => out.push('\x08'),
                Some('f')  => out.push('\x0C'),
                Some('v')  => out.push('\x0B'),
                Some('e')  => out.push('\x1B'),
                Some('0')  => out.push('\0'),
                Some('s')  => out.push(' '),
                // Unrecognized: drop the backslash, keep the next char
                // (preserves UTF-8 codepoints intact).
                Some(other) => out.push(other),
                // Trailing backslash — keep literal.
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
