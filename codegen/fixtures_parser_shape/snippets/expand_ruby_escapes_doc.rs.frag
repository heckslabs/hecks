/// Expand Ruby-style double-quoted string escapes byte-for-byte.
///
/// Ruby is the source of truth for `.fixtures` files because they're
/// loaded via `Kernel.load` — the string body IS Ruby source, and
/// Ruby's parser applies these substitutions before the DSL builder
/// sees the value. We reproduce the common subset here so the Rust
/// parser yields identical attribute values.
///
/// Covered:
///   \\ \" \'    — literal backslash / quote / apostrophe
///   \n \t \r    — newline / tab / CR
///   \a \b \f \v — bell / backspace / form feed / vertical tab
///   \e \0 \s    — escape (0x1B) / null / space (Ruby-specific)
///   any other `\X` — backslash dropped, X kept (Ruby's rule for
///                     unrecognized escapes in double-quoted strings)
///
/// Deferred (see followup i38-exotic): `\xNN`, `\uNNNN`, `\<digits>`
/// octal, `\C-x` / `\M-x` control-meta, and `\<newline>` line
/// continuation. None of these appear in current fixtures; add them
/// when a real fixture needs one.
