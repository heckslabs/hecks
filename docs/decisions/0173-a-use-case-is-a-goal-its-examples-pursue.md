# A use case is a goal its examples pursue

**Status:** Accepted (owner delegated the choice, 2026-11-02). Date: 2026-11-02. Built 2026-11-02 (see the
addendum). Adds one header to the
`.examples` form (ADR 0131), read by `hecks-parse examples`, the behaviors runner and narrate; no bluebook
grammar word.

## Context

Alistair Cockburn's use case names a goal a person has, at the level of "order a pizza" or "publish an
article": who has it, the main scenario of several steps that reaches it, and an extension for each way a
step can fail. Hecks describes behaviour one command at a time, and several pieces already carry part of
that shape:

- **`goal`** on a command (`command.bluebook`) is documentation (ADR 0025): projections print it, and no
  check or runtime effect reads it.
- **`role`** on a command names who may call it, and means Governance's access control (ADR 0131 allows
  several).
- **`given`** and a port operation's `refuses` are the ways one command can fail.
- **`process_manager`** strings commands together across aggregates, with `compensates` for legs to undo.
- **`.examples`** (ADR 0131 item 8) are Given/When/Then scenarios. `Background:` introduces people and
  their roles (`Remy is a Chef`), `Then it is refused because …` quotes a rule's own sentence, and every
  name is checked against the chapter, so an example can only mean something the domain declares.

None of these says "these steps are one goal a person has". ADR 0138 removed the one construct that grouped
commands, the all-or-nothing bulk mode, because the aggregate is the transaction (ADR 0137); a use case
cannot be a transaction either.

Three directions were weighed: (a) nothing new, with narrate presenting a process manager and its examples
as a use case; (b) let `.examples` name the goal its examples pursue, and check them against it; (c) a
`use_case` construct in the bluebook. ADR 0025's test decided between them: one idea, one spelling, and a
word earns its place by a check or a runtime effect. (a) adds no check. (c) is a second spelling of what
`process_manager` and `.examples` already say, and its natural check, "every refusal a step can meet has
an extension", is circular, since nearly every command has `given`s and every step would warn until
someone wrote an extension whose only effect is to silence it. (b) reuses a file, a compiler and a name
check that exist, and its check reads what someone wrote rather than demanding more of it.

## Decision

1. **`Goal:` opens a use case inside an `.examples` file.** It is written in the domain's words and names
   the person who pursues it, who must be one of the `Background:` people:

   ```
   Examples for: Shop

   Background:
     Remy is a Chef
     Sam is a Viewer

   Goal: Remy serves a pizza someone ordered
     Example: A topping goes on a pizza before the order is closed
       Given Remy creates a pizza with name "Margherita"
       And Remy adds a topping to it with note "basil"
       When Remy closes it
       Then the order is closed

     Example: A closed order cannot be closed again
       Given Remy creates a pizza with name "Quattro"
       And Remy closes it
       When Remy tries to close it
       Then it is refused because only an open order can be closed
   ```

   Examples outside any `Goal:` stay as they are; a goal is optional.
2. **The first example under a goal is its main scenario; the others are its extensions.** That is
   Cockburn's shape with no further headers: the main scenario reaches the goal, and each extension shows
   one way a step of it fails or branches.
3. **The actor is a person, not a role.** Cockburn's actor is whoever has the goal; in an `.examples` file
   that is a `Background:` person, and their role is what Governance checks for each command they call.
   `role` keeps its one meaning, access control, and no `actor` word is added.
4. **Two checks hold a goal to its examples.** Both run where the examples are compiled (`hecks-parse
   examples` and the behaviors runner), beside the existing name check:
   - `goal_without_success` (error): the main scenario ends in a refusal, so nothing under the goal
     reaches it.
   - `extension_off_path` (error): an extension's `When` calls a command that the main scenario never
     calls, so it is an example of a different goal.
   Neither asks for an extension per `given`: a goal is checked against the examples someone wrote.
5. **Narrate reads a goal as a use case.** The narrate projection renders each goal as its person, its
   main scenario and its extensions, in the sentences the examples already hold.
6. **Only the user-goal level.** A summary goal that groups other goals is not part of this decision; it
   earns its place when a domain needs one.

## Consequences

- The `.examples` reader gains `Goal:` and indentation of the examples under it, in Ruby and in
  `hecks-parse examples` together, with the conformance between them kept as ADR 0131 keeps it.
- The compiled `.behaviors` text is unchanged by a goal: each example still runs as it does today, and a
  goal adds checks and narration only.
- The corpus use is `spec/fixtures/sentence_examples/shop/shop.examples`, which gains the goal above, and
  Miette's reflection (a session ends, a perception asks the thinker, the answer is recorded or refused) is
  the first external case.
- `goal` on a command stays what it is: the purpose of one command. A `Goal:` in examples is a person's
  purpose across commands. The ADR 0025 test is met because the two name different things, at different
  levels, in different files; the narrate output says which is which.
- A use case that crosses aggregates is still carried out by a `process_manager` or by the person
  dispatching each step; the goal describes it and checks its examples, and adds no runtime.

## Alternatives considered

- **(a) Nothing new.** Rejected: narration alone checks nothing, and a process manager does not say whose
  goal it serves.
- **(c) A `use_case` construct in the bluebook.** Rejected: it repeats `process_manager` and `.examples`,
  its natural check is circular, and it needs a grammar row and a Rust parser change for no check (b)
  cannot make.
- **An `Actor:` header.** Rejected: the person is already named in `Background:` and in each step, so a
  header would restate it.

## Addendum: what is built (2026-11-02)

`Goal:` is a phrase of the `Examples` context (`examples_goal` in the Sentence bluebook, opening a
`Goal` block whose examples are `goal_example`), read by `hecks-parse examples`
(`rust/parser/src/sentence/examples.rs`), which the behaviors runner and the Ruby sentence form
already call, so there is one reader. A goal must name a `Background:` person; `goal_without_success`
and `extension_off_path` refuse the file with the line and the goal's words. The compiled `.behaviors`
text is unchanged by a goal. The corpus use is `spec/fixtures/sentence_examples/shop/shop.examples`,
whose first three examples now stand under `Goal: Remy serves a pizza someone ordered`, and
`spec/sentence_examples_spec.rb` pins a goal that runs and each refusal. `docs/sentence-form.md` says
how to write one.

Item 5, narration, is built as `Projector::NarrateProjector::UseCases`: given `options[:examples]`, the
narrate projection ends with a "Use cases" section, one heading per goal, its main scenario and then its
extensions, each line quoted from the file. `hecks narrate` passes the `.examples` files under the
domain's directory. `spec/narrate_use_cases_spec.rb` pins it against the shop's goal.
