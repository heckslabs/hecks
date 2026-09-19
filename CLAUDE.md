# CLAUDE.md

Comments you write in this repository's Ruby (`lib/`, `bin/`, `spec/`,
`examples/`) must match `docs/COMMENT_STYLE_GUIDE.md`. In particular:

- No all-caps lead-ins for emphasis — use `**bold**` instead
  (`docs/COMMENT_STYLE_GUIDE.md` section 5).
- No design history in comments ("used to", "previously", "before this
  change", PR numbers) — state the system as it is now and keep the
  reason (section 4).
- Public methods carry YARD tags (section 1); a class or module
  comment says what it is, not what it contains (section 2).
- Comment lines stay under 100 characters (section 6).

Check a tree with `bin/standardize_comments --check <path>` before
calling comment work done.
