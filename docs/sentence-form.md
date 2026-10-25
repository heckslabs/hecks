# Writing a domain in plain sentences

A `.bluebook` can be written as sentences instead of Ruby. A file whose first line is
`Domain: <name>` is read as sentences; everything else about the file, its name, its place on
disk, how it boots and what it produces, is the same. This guide is for the person who knows the
business. The reasons for the design are in ADR 0131.

## A domain

```
Domain: Cms
  A site's pages, kept as drafts until they are published.

Aggregate: Page
  One page of a site's writing, kept as a draft while it is written, published when it is ready.

  A page is identified by its slug.

  It has:
    a slug: page slug
    a title: page title
    a published on: published on, optional

  A page slug has a value: text.
    Rule "a page has a slug" holds when the value is not empty

  A page title has a value: text.
    Rule "a page has a title" holds when the value is not empty

  A published on has a value: whole number.
    Rule "a publication date is a real moment" holds when the value is at least 0

  Lifecycle: status, starting as draft
    Publish moves a page from draft to published
    Withdraw moves a page from published to withdrawn

  Command: Draft
    Goal: Start a new page, unpublished
    Who: Editor
    When a slug and a title are given
    Then the slug and the title are set
    And PageDrafted is announced

  Command: Publish
    Goal: Put a drafted page on the site
    Who: Editor
    It acts on an existing page
    When a published on is given
    Given "only a draft can be published" holds when the status is draft
    Then the published on is set
    And PagePublished is announced

  Command: Withdraw
    Goal: Take a page off the site
    Who: Editor
    It acts on an existing page
    Given "only a published page can be withdrawn" holds when the status is published
    Then PageWithdrawn is announced

  Query: Drafts
    The pages not yet published, by slug.
    Where the status is draft
    Ordered by slug.value, ascending
```

Indent with spaces. A line that starts with `#` is a comment. The paragraph under `Domain:`,
`Aggregate:` and `Query:` says what it is for. Types are `text`, `whole number`, `decimal number`,
or a value object you describe in the same file.

## When something happens, and when the outside is asked

A policy waits for an event and then runs a command, or asks the outside for something:

```
Policy: Check Credit When Submitted
  Whenever OrderSubmitted is announced
  Then check credit is asked

Policy: Approve When Credit Clears
  Whenever CreditCleared is announced by an order
  Then Approve runs

Policy: Decline When Credit Is Refused
  Whenever CreditRefused is announced by an order
  Then Decline runs with the reason
```

The domain says the question (`check credit`) and which events can answer it. Who answers is
wiring, so it lives in the hecksagon, and an event the outside announces is named with the
aggregate it belongs to (`announced by an order`). A command's own events need no `by`.
`Then Decline runs with the reason` passes the event's `reason` to the command.

## Examples that run

An examples file sits beside the chapter it is about and has the same name, with the extension
`.examples` (`page.bluebook` and `page.examples`).

```
Examples for: Cms

Background:
  Dana is an Editor
  Sam is a Viewer

Example: A drafted page can be published
  Given Dana drafts a page with slug "about" and title "About us"
  When Dana publishes it with published on 1700000000
  Then the page is published
  And PagePublished is announced

Example: A published page cannot be published again
  Given Dana drafts a page with slug "about" and title "About us"
  And Dana publishes it with published on 1700000000
  When Dana tries to publish it with published on 1700000001
  Then it is refused because only a draft can be published

Example: Only an editor may take a page down
  Given Dana drafts a page with slug "about" and title "About us"
  And Dana publishes it with published on 1700000000
  When <person> tries to withdraw it
  Then it is refused because only an Editor may do it

  Where:
    | person |
    | Sam    |
```

- A person is a role, and each step runs as that role. `the Editor drafts …` names a role outright.
- `drafts a page with …` makes one; `publishes it` acts on the page made earlier in the example.
- `tries to` is how a step that should be refused reads, and the example then has to say why. The
  reason is the rule's own sentence, copied from the `Rule` or `Given`.
- An example has one `When`. A `Where:` table runs it once per row.
- Every name is checked against the domain, and a wrong one is refused with the names that would
  have worked.
- A domain that asks the outside needs a port to ask it through before it can run at all. Put a
  Memory-bound hecksagon beside the examples named `<name>_behaviors.hecksagon` (Pizzas keeps one,
  `examples/pizzas/pizzas_behaviors.hecksagon`); it is booted with the chapter. Nothing answers
  the ask in an example, and the runtime refuses it, so an example of such a command is best
  about the order's state (`Then the order is submitted`) rather than the list of events.

Run them like any behaviors file: `hecks run_behaviors target=page.examples`, or give a directory
and every `.behaviors` and `.examples` file under it runs.

## Tools

| | |
|---|---|
| `hecks-parse format --chapter Cms page.bluebook` | prints the file in the one canonical wording; works on a Ruby-form file too |
| `hecks-parse render --chapter Cms page.bluebook` | prints the Ruby-form text for the same chapter |
| `hecks-parse examples --chapter Cms --examples page.examples page.bluebook` | prints the `.behaviors` text the examples run as |
| `hecks-lsp` | squiggles at the column a sentence went wrong, and offers the sentences legal at the cursor |
| `hecks language_run.project_phrase_table --confirm` | regenerates the parser's table of sentences from the `Sentence` chapter |

`hecks-parse` is built with `cargo build --release --manifest-path rust/parser/Cargo.toml`; a
sentence file needs it to boot, found at `HECKS_PARSE_BIN`, in `rust/parser/target/`, or on the
`PATH`.

## What it cannot say yet

A command run by more than one role, a total over a list, and a `.hecksagon` beside a chapter
written as sentences are refused by name. So are read models, process managers, entities, closed
sets, list attributes, defaults and `from:` guards; write that chapter in the Ruby form.
