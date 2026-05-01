/// Given `s` and the byte index of an opening `{`, return the byte
/// index of the matching closing `}` — respecting nested braces and
/// skipping string literals. Returns None if unbalanced (which in v1
/// means the schema spans multiple lines; we decline to parse it).
