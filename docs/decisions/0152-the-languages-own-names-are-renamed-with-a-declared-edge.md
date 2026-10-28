# The language's own names are renamed with a declared edge, not kept

**Status:** Accepted. Date: 2026-10-28. Settles tier 3 of ADR 0134 and the language-event half of
ADR 0146.

## Context

ADR 0134 retired "chapter" in three tiers and left the third undecided: the language's own
bluebooks still said `ChapterNamespace`, `ChapterDeclared`, `ChapterAttached` and "a chapter is
named" while the prose said "bluebook". ADR 0146 left the setter-style events of the language
(`MedianFieldSet`, `PieceHeld` and their siblings) alone on the grounds that the Rust parser and the
IR goldens name them.

Both reasons turned out smaller than stated. The event names appear only in the language
bluebooks, the Bluebook and Hecksagon IR goldens, and one reachability spec; no Rust table names
them. A value object's type name is part of a bluebook's storage shape in the ledger, but stored
data never carries a type name, so a rename moves no data.

## Decision

**Rename.** The language's own names follow the domain, and a rename that changes a ledgered shape
declares an edge for it. Keeping the old names would leave the mismatch for good.

- Events become domain facts: `MedianDeclared`, `SumDeclared`, `AvgDeclared`, `MinDeclared`,
  `MaxDeclared`, `PercentileDeclared`, `AnyDeclared` and `AllDeclared` (siblings of the existing
  `CountDeclared`), `PieceOptionDeclared` for `PieceHeld`, `BluebookDeclared` and
  `BluebookAttached` for the `Bluebook` aggregate's two events, and `BluebookAttached` for the
  Hecksagon's `Attaches`.
- `ChapterNamespace` is `BluebookNamespace`. The Hecksagon's `ChapterName` is
  `AttachedBluebookName`, because `BluebookName` already names a bluebook's own name, and its
  `chapter` argument is `bluebook`. The refusal strings say "a bluebook is named" and "a bluebook
  is core, supporting, or generic".
- **The edge.** The Bluebook shape moved `bfdb48` to `1b447c`, and `translations/2-1b447c.bluebook`
  declares `retype "ChapterNamespace", to: "BluebookNamespace"`. Nothing is stored differently, so
  the edge has no data rules; it states that the two names are one shape, which is what lets the
  ledger accept the move. The Hecksagon's value object is not part of the ledgered shape and needed
  none.
- **No alias.** An event name is not an interface: nothing outside the bluebooks subscribes to a
  language event. The old names stay readable in git history and in this ADR.

**Not done here: tier 2's argument names.** The `chapter` argument of the `Hecks` tooling
queries, the Composer `chapter_name` key and the invariant text in `composer.bluebook` and
`tooling.bluebook` are the arguments of the command-line and Composer interfaces. ADR 0134 gives
those a deprecation alias period, so they are renamed with the tier 2 interface step, not here.

**Left alone: Privacy `Marked` and `Unmarked`,** which belong to the Privacy work.

## Consequences

- `spec/golden/ir/Bluebook.json` and `Hecksagon.json` were regenerated with the pinned JSON
  (`RUBYOPT="-rbundler/setup"` on the launcher run gives it), and the diff is the renames only.
- `spec/meta_rule_reachability_spec.rb` names the renamed rules.
- A future rename of a language name is the same two steps: rename in the bluebook, then run
  `conformance_run.check_shape_ledger` and commit the edge it asks for.
