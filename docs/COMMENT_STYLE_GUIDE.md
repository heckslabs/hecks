# Comment style guide

The standard for comments in this repository's Ruby: `lib/`, `bin/`, `spec/`
and `examples/`. `bin/standardize_comments` checks the parts of it a machine
can check. The rest is a checklist for whoever reads the diff.

Nothing enforces this in CI. `bin/standardize_comments` is run by hand.

## 1. Public methods carry YARD tags

Doc comments use [YARD](https://yardoc.org) tags with Markdown markup (see
`.yardopts`). Every public method gets a comment directly above its `def`:

```ruby
# Finds the single adapter bound to a port, refusing an ambiguous wiring.
#
# @param registry [Runtime::Registry] the booted registry to search
# @param port [String] the port name, such as `"authorization"`
# @return [Module] the adapter implementing `port`
# @raise [Runtime::WiringError] if no adapter, or more than one, implements it
def adapter_for(registry, port:)
```

- **Lead sentence.** Required, except on `initialize`. It starts with a verb,
  says what the method does for its caller, and adds something the name does
  not. A blank `#` line separates it from the tags. Existing prose that
  explains *why* stays, above the tags.
- **`@param name [Type] description`**, one per parameter, in declaration
  order. A block takes `@yield`, plus `@yieldparam` and `@yieldreturn` when
  the block's arguments or result matter to the caller.
- **`@return [Type] description`**. Omitted only on `initialize` and on
  writers (`name=`). A method called for its effect is `@return [void]`.
- **`@raise [ErrorClass] condition`** for every exception a caller could
  reasonably rescue, wherever it originates, including one raised by a
  delegate. Any literal `raise` in the body must be covered. Skip accidents
  such as `NoMethodError`.
- Every tag has a description. State units and formats ("Unix epoch
  seconds"), Hash keys, and what `nil` or `[]` means.
- A line that would pass 100 characters continues on the next line, indented
  two spaces past the tag.

### Types

Types come from the code, never from the parameter's name or nearby prose.
Read the body, what it calls, and at least two callers.

- Name the most concrete type the code supports: `Bluebook::Bind`,
  `Array<Persistence::AppendOnly::Entry>`, `Hash{Symbol => String}`.
- Namespaces are written relative to `Hecks`.
- If a caller passes `nil`, the body guards against it, or the default is
  `nil`, the type includes `nil`. If any path returns `nil`, so does `@return`.
- `[Object]` is for a value the code truly accepts in any shape. When the
  shape belongs to an adapter this repository does not ship, write `[Object]`
  and say "adapter-defined".
- Identifiers go in backticks. Do not use YARD `{Link}` syntax.

### Exemptions

- Methods whose contract is fixed by Ruby itself need nothing: `to_s`,
  `inspect`, `==`, `eql?`, `hash`, `<=>`, `to_h`, `to_a`, `to_proc`,
  `method_missing`, `respond_to_missing?`.
- `(see #other_method)`, `@api private` and `:nodoc:` stand in for tags.
- Private methods take no tags. Give one a short comment only when its logic
  is not obvious from its name and body.
- Helper methods defined inside a `*_spec.rb` file are test scaffolding, not
  API, and take no tags. Shared helpers under `spec/support` and
  `spec/fixtures` are documented like any other code.

## 2. Classes and modules: what it is, not what it contains

A class or module comment says what the thing is, why it exists as its own
thing, and, where it helps, what it is not. It never inventories the methods
below it.

A comment longer than about 25 lines is broken up with `##` Markdown headers:

```ruby
# What time it is, the one fact a domain cannot derive and must not invent.
#
# ## Why a port and not `Time.now`
#
# A staleness rule is untestable against the real clock...
module Clock
```

A module reopened across several files is documented once, at its primary
opening.

## 3. Code comments explain why

A comment earns its place by saying what the code cannot: why this approach
and not the obvious one, which edge case a line exists for (stated at that
line), or which invariant the surrounding code relies on.

```ruby
# nil first: Postgres and Memory disagree on NULL ordering by default, so
# this pins it rather than depending on either engine's comparator.
rows.sort_by { |row| [row[field].nil? ? 0 : 1, row[field]] }
```

A comment that narrates the next line in English is deleted. If the code
needs narrating, it needs a better name or an extracted method.

## 4. No design history

Comments describe the system as it is. The linter flags "used to", "was
originally", "previously", "formerly", "historically", "renamed from",
"before this change", "an earlier version", "has since", and pull request
numbers.

Rewrite the comment in the present tense and keep the reason, which is the
valuable part:

```ruby
# Before: This used to raise, which hid a half-written snapshot. It now
#         returns nil.
# After:  Returns nil rather than raising, because raising hides a
#         half-written snapshot.
```

The history itself belongs in `docs/decisions/NNNN-slug.md`. A comment may
cite an ADR, an audit document, a spec, or a bug ID that already exists.
Never invent one.

## 5. Markdown emphasis, never all caps

All-caps words are not emphasis. Use backticks for identifiers, `##` headers
for structure, and `**bold**` sparingly.

The one routine use of bold is a paragraph's heading phrase, the short
lead-in before a dash or full stop:

```ruby
# **The bus, not a door** — every call goes through here.
```

Emphasis on a single word in running prose is normally just dropped. Keep it,
as bold, only where the sentence misreads without it.

Capitals stay where they are the correct spelling: initialisms (`SQL`, `REST`,
`ADR`), SQL written as SQL (`SELECT ... FROM`, `BEGIN`/`COMMIT`), proper nouns
(`Ruby`, `Postgres`, `GitHub`), and constant names. A constant named in prose
goes in backticks (`` `NAME` ``); the linter reports a bare one as
`bare_constant` because it cannot tell a reference from a shout.

## 6. Comment lines stay under 100 characters

Wrap at a word boundary. Do not break inside a backtick span or a URL.

## Checking a tree

```
bin/standardize_comments --report lib/hecks             # summary tables
bin/standardize_comments --check  lib/hecks             # one line per violation
bin/standardize_comments --fix    lib/hecks             # all_caps and long_line only
bin/standardize_comments --code-unchanged main lib      # prove an edit was comment-only
```

`--fix` rewrites only the two mechanical categories. Do not run it over doc
comments written by hand without reading the result. Everything else needs
someone to read the code. `--code-unchanged REF` compares each file's
non-comment tokens with `REF` and fails if any differ, which is how a
comment-only change is shown to be one.

Whether documented behaviour is backed by a running example is a separate
concern with its own gate: see `bin/doc_coverage`.
