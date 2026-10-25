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

1. **The bluebook accepts a second syntax, the bizbook form.** A `.bluebook` file is either
   Ruby-shaped (`Hecks.bluebook "X" do`) or plain sentences (`Domain: X`); its first line
   picks the grammar. `hecks-parse` reads both into the same `ir.json`, so every
   projection, host, generator and conformance check cannot tell which wrote it. A file is
   wholly one form; files in a project may differ; mixing forms inside a file is refused.
   One extension means no new file kind for globs, `loads` or editors. "Bizbook" names the
   sentence form. A construct with no phrase rows yet stays in Ruby form in another file,
   so a project adopts the form file by file. Ruby is never embedded in a sentence file.
2. **Bluebook side, not hecksagon.** A bizbook declares what the domain is and does. It
   names no database, clock or network. Wiring stays in `.hecksagon`; persistence stays
   memory by default.
3. **There is no step-definition layer.** The sentences *are* the declaration. The
   grammar is a closed controlled English held as rows in the Vocabulary (the way keyword
   rows are), so adding a phrase is a `propose!` / `admit!` of a row and the parser,
   reference and editor support are projected from it. A sentence that matches no row is
   a parse error that names the nearest rows. No free-form language understanding.
4. **Gherkin's words keep their meaning, mapped onto the IR:**

   | Bizbook | IR |
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
   | `Whenever <event>, ask <outside> to …` | policy with `ask` |
   | `Example:` tables | executable examples (below) |

5. **Examples are the tests.** An example compiles to the
   `.behaviors` tests of that command, so the readable file is also its own conformance
   corpus and cannot drift from what runs. Authors write no `.behaviors` for bizbook projects.
6. **Expressions are phrases over named things.** `Given the order has at least one
   topping` resolves to the canonical expression the existing expression machinery
   (`rust/parser/src/expr`) already emits; a phrase row names its expression template.
   Field and type names come from the bizbook's own `It has:` lines, spelled as a person
   would ("customer name" is `customer_name`).
7. **IR to sentences is a projection.** Because both forms share the IR, any existing
   bluebook can be rendered in sentence form (and back) by a formatter. Comments are not
   in the IR and are lost; a construct with no phrase row renders in Ruby form.
8. **Examples are their own file.** `orders.examples.bluebook` says `Examples for: Order`
   and holds `Background:` (people bound to roles), `Example:` and `Where:` tables. An
   actor on a `When` is the command's role. A refusal is matched by the rule's own
   sentence, not a message string. An outside party (a credit check) is an `ask`: a policy
   asks on an event, the outside answers with an event, and a policy triggers the next
   command. The declaration holds the question, the answer events and any threshold the
   business sets; the hecksagon picks the adapter; examples stub the answer
   (`When Credit Check approves the order`). `needs` is not used: it supplies only `now`
   and `today`.

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
- Two forms for one IR need a round-trip check: a sentence file and its Ruby-form
  rendering must produce byte-equal `ir.json` (a `check_conformance` pair).
- A project can end up holding both forms; the formatter keeps that tolerable.

## Known gaps (the sentence form cannot yet say these)

- `Command.role` is a single role (`rust/parser/src/ir.rs`); "a Customer or a Sales Rep
  can cancel" needs several roles on a command.
- A total over a list (quantity × price summed over line items) may be outside the
  expression machinery; unverified.
- `nothing is recorded` after a refusal is a test assertion, not a rule: `.behaviors` side.

## Open questions

- Whether examples use `.examples.bluebook` or their own extension.
- How much of a command's `Then` can be inferred versus stated (mutation ops, `emits`).
- Whether bizbook files get a formatter that normalises phrasing, so diffs stay quiet.

## Next

1. Admit the first phrase rows for `Domain`, `Aggregate`, `It has`, `Rule`, `Command`.
2. Parse them in `rust/parser` into IR; check the Pizzas `Order` against the bluebook IR.
3. Compile examples to `.behaviors`.
4. Hand-write the Order domain (declaration and examples) as a `.bluebook`, run
   `model_check`, and let it confirm or add to the gaps above.
