# An argument can say it sets its field

**Status:** Accepted.
Date: 2026-10-28.

## Context

A command that writes the owner's field from an argument of the same name says it twice:
`attribute :title, Title` declares the argument and `sets :title` writes it. Across the Ruby-form
bluebooks most plain `sets` lines are exactly this pair. The second line carries no information the first does not,
and a sweep that adds an argument has to remember to add its write.

Making the write implicit for every same-named argument would change commands that take an argument
on purpose and do not write it, so it cannot be inferred.

## Decision

`attribute` in a command takes `sets: true`. It declares the argument and records the plain
`sets :name` that a following line would, at the same position in the command's mutations.

- The IR is identical to the two-line form. Nothing downstream reads the spelling: the Rust kernel,
  the generators, the sentence formatter and every projection take the IR as before.
- `sets :x` stays valid, and is still how `to:`, `append:`, `increment:` and the other ops are
  written. A command may mix the two.
- `sets: true` is refused when the owner declares no field of that name, in Ruby and in `hecks-parse`
  alike, and takes `true` or nothing.
- The row is a `sets` argument of the Command-context `attribute` in the Syntax chapter, so the
  parser table and the reference are projected from it.

## Consequences

The corpus is swept mechanically: a pair is folded only where the folded mutations would stay the
leading mutations in attribute order, so the exported IR of every swept chapter is unchanged.
Commands that interleave other mutations between plain writes keep their two lines.
