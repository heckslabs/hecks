# A domain can be written in plain business sentences

**Status:** Proposed. Not built. Date: 2026-10-25.

## Context

A bluebook is Ruby-shaped (`Hecks.bluebook "X" do … end`, `attribute :name, Type`,
`invariant("…") { … }`). The people who know the rules of a business (what may be sold,
when an order is refused, what happens next) cannot write it, so they describe it and
someone else transcribes it. `.behaviors` files are not the answer: they test a domain
that already exists, in developer notation (`setup`, `input`, `expect` with hashes).

Gherkin shows the shape business people will write: indented plain text, one sentence a
line, `Given` / `When` / `Then`. Its weakness is also known: the sentences are bound to
code by hand-written step definitions, so the readable file and the running system drift.

## Decision

1. **A bizbook is a second source language for the same IR.** A `*.bizbook` file is plain
   text that `hecks-parse` reads into the same `ir.json` a `.bluebook` produces. It is
   parallel to the bluebook, not a layer over it: every projection, host, generator and
   conformance check works from the IR and cannot tell which source wrote it.
   **A project uses bluebooks or bizbooks, never both.** `model_check` refuses a project
   holding both, so no `loads` crosses the line and no reader has to know two grammars at
   once. Projects meet through the IR, so a bizbook project may depend on a package written
   in bluebooks and the reverse. The bluebook stays; a bizbook may supersede it later,
   decided by use, not by this ADR.
2. **Bluebook side, not hecksagon.** A story declares what the domain is and does. It
   names no database, clock or network. Wiring stays in `.hecksagon`; persistence stays
   memory by default.
3. **There is no step-definition layer.** The sentences *are* the declaration. The
   grammar is a closed controlled English held as rows in the Vocabulary (the way keyword
   rows are), so adding a phrase is a `propose!` / `admit!` of a row and the parser,
   reference and editor support are projected from it. A sentence that matches no row is
   a parse error that names the nearest rows. No free-form language understanding.
4. **Gherkin's words keep their meaning, mapped onto the IR:**

   | Story | IR |
   |---|---|
   | `Domain:` + paragraph | domain, `vision` |
   | `Aggregate:` + paragraph | aggregate, `description` |
   | `It has:` lines | attributes, value objects, `identified_by`, `optional` |
   | `Rule:` sentence | invariant |
   | `Lifecycle:` lines (`available → sold`) | lifecycle, transitions |
   | `Command:` + `Given` | command, `from:` state and `given`s |
   | `When` | the command's arguments (who supplies what) |
   | `Then` | mutations, `ensures`, `emits` |
   | `But refuse … because "…"` | a `given` with its refusal message |
   | `Whenever <event> then <command>` | policy |
   | `Example:` tables | executable examples (below) |

5. **Examples are the tests.** An example compiles to the
   `.behaviors` tests of that command, so the readable file is also its own conformance
   corpus and cannot drift from what runs. Authors write no `.behaviors` for bizbook projects.
6. **Expressions are phrases over named things.** `Given the order has at least one
   topping` resolves to the canonical expression the existing expression machinery
   (`rust/parser/src/expr`) already emits; a phrase row names its expression template.
   Field and type names come from the story's own `It has:` lines, spelled as a person
   would ("customer name" is `customer_name`).
7. **A bizbook must reach full coverage before a project can adopt it.** Because a project
   cannot mix, there is no bluebook beside it to hold queries, read models, process
   managers or ports. Each such construct needs phrase rows first; until it has them, a
   project that uses it stays on bluebooks. Ruby is never embedded in a bizbook.
8. **Examples are their own file.** `orders.examples.bizbook` says `Examples for: Order`
   and holds `Background:` (people bound to roles), `Example:` and `Where:` tables. An
   actor on a `When` is the command's role. A refusal is matched by the rule's own
   sentence, not a message string. Stubbed outside facts (a credit check) are ports: the
   declaration names them, the hecksagon wires them, the examples stub them.

## Sketch

```
Domain: Pizzas
  Put toppings on a pizza and sell it to a customer.

Aggregate: Order
  An order that gathers toppings on a pizza and is eventually sold.

  It has:
    a name, which identifies it
    a pizza
    toppings, a list of topping
    a customer name, optional

  Rule: a price is never negative
  Lifecycle: an order is available, then sold

  Command: Purchase
    Given the order is available
    And it has at least one topping
    When a customer name and an amount are given
    Then the customer name is recorded
    And the order is sold
    But refuse unless it has at least one topping because "at least one topping"

    Example: a loaded pizza sells
      | name   | toppings | customer name | result |
      | Loaded | Basil    | Chris         | sold   |
```

## Consequences

- Business authors get a file they can read and edit without Ruby punctuation; the IR,
  Rust kernel and conformance corpus are untouched.
- The phrase table is the new surface to keep honest. It is generated into the reference
  and editor grammar like every other table, and `measure_doc_coverage!` extends to it.
- Two sources for one IR need a round-trip check: a bizbook project and its bluebook
  rendering must produce byte-equal `ir.json` (a `check_conformance` pair).

## Open questions

- Whether examples use `.examples.bizbook` or a shorter `.examples.biz`.
- How much of a command's `Then` can be inferred versus stated (mutation ops, `emits`).
- Whether story files get a formatter that normalises phrasing, so diffs stay quiet.

## Next

1. Admit the first phrase rows for `Domain`, `Aggregate`, `It has`, `Rule`, `Command`.
2. Parse them in `rust/parser` into IR; check the Pizzas `Order` against the bluebook IR.
3. Compile `Example:` tables to `.behaviors`.
