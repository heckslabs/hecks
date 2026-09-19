# Comment style guide

This is the standard for comments and doc comments across `lib/`, `spec/`, and
`examples/`. `bin/standardize_comments` checks a source tree against it
mechanically for the categories that can be checked mechanically; the rest is
a checklist for the person (or agent) reading the diff.

Nothing enforces this in CI. It exists so a large, incremental cleanup (see
`docs/decisions/` for how this codebase records that kind of decision) has one
target to converge on, one file at a time, instead of every file re-deriving
its own voice.

## 1. Public methods get RDoc

Every public method gets a doc comment directly above its `def`, with tags in
this order:

```ruby
# Finds the adapter bound to a port, refusing when the wiring is ambiguous.
#
# @param registry [Runtime::Registry] the booted registry to search
# @param port [String] the port name, e.g. `"authorization"`
# @return [Class] the adapter class implementing `port`
# @raise [Runtime::WiringError] if zero or more than one adapter implements it
def adapter_for(registry, port:)
  ...
end
```

- `@param name [Type] description` — one line per parameter, in declaration
  order, keyword or positional. A block parameter gets `@yield` (and
  `@yieldparam`/`@yieldreturn` when the block's own arguments or return value
  matter to the caller).
- `@return [Type] description` — omit only for `initialize` and `attr`-style
  writers (`foo=`), where the return value is never the point.
- `@raise [ErrorClass] condition` — one line per exception the method itself
  raises (not one it merely propagates from something it calls), only when
  that's part of the contract a caller needs to know, not incidental to the
  implementation.
- A leading prose line (like the `Finds the adapter...` line above) is
  required and stands on its own — it says what the method *does*, not what
  its tags already say structurally.

A trivial, self-evident method (`to_s`, `==`, a plain `attr_reader`) doesn't
need this ceremony. If you'd have to strain to write a `@return` that says
more than the method signature already does, that's the signal it's trivial.

### Private methods

Document a private method only when its logic isn't obvious from its name and
body — a non-obvious algorithm, a subtle precondition, an ordering
requirement. Skip RDoc tags for private methods; a one- or two-line prose
comment explaining the *why* is enough. Most private methods need nothing at
all.

## 2. Classes and modules: what it is, not what it contains

A class or module doc comment answers "what is this," "why does it exist as
its own thing," and (when non-obvious) "what is it not" — never an inventory
of the methods below it, which the reader can already see.

Use `##` markdown headers to break up anything longer than a few lines:

```ruby
# The single point every dispatch, query, and boot goes through.
#
# ## Why this exists
#
# A caller never talks to a `Registry` or `Dispatcher` directly — every
# door onto a domain (CLI, HTTP, a test) goes through this module so there
# is exactly one place that knows how a `summary:`/`source:` pair becomes
# an audited call.
#
# ## What it is not
#
# Not a place to add new vocabulary. If a caller needs a new way to talk
# to a domain, that belongs in the domain's own bluebook.
module Facade
```

A class doc longer than ~25 lines *must* use `##` headers — see
`bin/standardize_comments`'s `unstructured_class_doc` check. If you can't
find a natural section break, the doc is probably trying to say too much;
consider whether some of it belongs at the ADR it should be citing instead
(see §4).

A module reopened across multiple files only needs this once, at whichever
opening reads most like the "primary" one.

## 3. Code comments: explain why, not what

A comment on a line of code earns its place by saying something the code
can't say on its own:

- **Why** this approach and not the obvious alternative.
- **What edge case** this line exists for, stated at the line handling it —
  not three paragraphs above, disconnected from the code that acts on it.
- **What invariant** the surrounding code is relying on that isn't visible
  from the immediate context.

```ruby
# nil first: Postgres and Memory disagree on NULL ordering by default,
# so this pins it explicitly rather than depending on either engine's
# comparator default.
rows.sort_by { |r| [r[field].nil? ? 0 : 1, r[field]] }
```

Don't restate the code:

```ruby
# increment the counter
counter += 1
```

If a comment would just narrate the next line in English, delete it and let
the code speak. If the code is confusing enough to need narration, the fix is
usually a better name or an extracted method, not a comment.

## 4. No design history — cite an ADR instead

Comments narrate the *current* system, not how it got here. Banned phrasings
(the linter's `design_history` check flags these): "used to", "was
originally", "previously", "formerly", "historically", "renamed from",
"before this change", "in PR #NNN", "an earlier version".

That history is real and worth keeping — it belongs in
`docs/decisions/NNNN-slug.md` (see any file already in `docs/decisions/` for
the shape), not scattered through comments where it rots the moment someone
reads it without the context of when it was written. A comment that needs to
explain "why not the other way" cites the ADR:

```ruby
# Bad:
# This module used to be named McpDoor before the survey renamed it.

# Good:
# See ADR 0025 for why this is a bus, not a per-protocol door.
```

If there's no ADR yet for a decision worth recording, write one instead of
leaving the history in the comment.

## 5. Markdown emphasis, never ALL CAPS

Use `**bold**` for emphasis, `` `backticks` `` for code/identifiers, and `##`
headers for structure. Don't use ALL CAPS as an emphasis device.

```ruby
# Bad:
# THE BUS, NOT A DOOR — every call goes through here.

# Good:
# **The bus, not a door** — every call goes through here.
```

Capitals stay capitals when they're actually capitalized in real life:
acronyms and initialisms (`SQL`, `JSON`, `ADR`, `HTTP`), SQL keywords used as
SQL (`SELECT ... FROM`, `ON CONFLICT DO NOTHING`), real proper nouns (`Ruby`,
`Rust`, `GitHub`, `Postgres`), and this codebase's own real constant names
(`Runtime::WiringError`, `BOOT_ROOT`). None of those are "emphasis" — they're
just spelled that way.

## 6. Comment lines under 100 characters

Matches the line-length convention the rest of this codebase already uses.
Wrap prose at a word boundary; don't wrap in the middle of a
`` `backtick-quoted identifier` `` or a URL.

## 7. Doc coverage vs. doctest coverage

This guide is about comment *style*. Whether a documented behavior is backed
by a runnable example is a separate, already-solved concern — see
`bin/doc_coverage` and `docs/implemented/` for the doctest-presence gate, and
its own header comment for exactly what it does and doesn't guarantee. Don't
duplicate that mechanism here.

## Checking a tree

```
bin/standardize_comments --report lib/hecks       # summary tables
bin/standardize_comments --check  lib/hecks       # one line per violation
bin/standardize_comments --fix    lib/hecks       # rewrites all_caps + long_line only
```

Everything else — missing RDoc, missing `@return`, design-history phrasing,
an undocumented class — needs a person to read the code and write the real
comment. The `--fix` mode is a mechanical first pass, not a substitute for
that reading.
