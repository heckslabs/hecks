/// Extract the body of the first double-quoted string in `s`, honoring
/// `\"` as an embedded-quote escape. Returns the raw (still-escaped)
/// contents between the opening and closing quote, or None if there
/// isn't a complete pair. Used instead of parser_helpers::extract_string
/// for fixture attribute values so that strings like `"1/8\"=1'"` don't
/// terminate prematurely at the embedded `\"`.
