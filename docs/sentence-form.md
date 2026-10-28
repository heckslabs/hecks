# Writing a domain in plain sentences

**Status: built, not released.** Every example below is run by `spec/sentence_guide_spec.rb`, so
what it shows is what the parser accepts today.

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
`yes or no`, `true or false`, or a value object you describe in the same file.

## More to say about a thing

Everything the Ruby form can say has a sentence, so a bluebook written either way means the same
thing. This one uses most of them:

```
Domain: Library
  A library lends books to members and keeps count of what is out.
  This is a supporting domain
  Its version is v1

Aggregate: Book

  A book is identified by its isbn.

  Rule "a book has a title" holds when the title is not empty

  It has:
    an isbn: isbn
    a title: text
    a copies: whole number, default 1
    a shelf: shelf label, optional
    a kind: book kind
    an author: reference to author
    some tags: list of tag
    some loans: has many loan
    a rating: whole number, optional

  An isbn has a value: text, matching "^[0-9]{10}$".

  A shelf label has a value: text.

  A tag has a value: text.

  A book kind is one of: novel, poem and reference.

  A reading level has:
    a minimum age: whole number
    a label: text
    Rule "a minimum age is not negative" holds when the minimum age is at least 0

  Command: Lend
    Goal: Let a member take a book home
    Who: Librarian or Volunteer
    It can only happen from shelved and reserved
    It acts on an existing book
    When an isbn and an optional rating are given
    Given "a copy is free" holds when this is true: copies > 0
    Then the copies goes down by 1
    And the title is set to "lent"
    And the rating is set to what the copies was
    And the shelf is kept between 1 and 9
    And BookLent is announced
    Afterwards "a copy is out" holds when the copies is at least 0

  Query: By Kind
    It takes:
      a kind: book kind
    Where the kind is the kind
    Where the copies is at least 1
    Ordered by title, ascending
    Limited to 20

Aggregate: Author

  An author is identified by its name.

  It has:
    a name: text

  Command: Notify
    Who: Librarian
    When a name is given
    Then AuthorNotified is announced

Policy: Tell Author
  Whenever BookLent is announced
  For each by kind of the book
  Only when this is true: copies == 0
  Then Notify runs with the name from the title

Report: Loans By Kind
  How many books of each kind are out.
  It includes a book
  It groups by kind
  It counts them
  Where the copies is 0
```

- **The top of the file.** `This is a core / supporting / generic domain`, `Its version is …` and
  `Its module is …` sit under `Domain:`, as do `It attaches to …` and `It provides … :`.
- **What a thing has.** After the type, options follow a comma: `optional`, `default 1`,
  `matching "<pattern>"` and `admits <set>`. A type can be `list of tag`, `reference to author`,
  `has many loan`, `has one …`, `belongs to …`, `link to …` or `one of account or card`. A list
  reads as `some tags`.
- **Value objects.** `has a value: …` for one value, `has:` over several, `is one of: a, b and c`
  for a closed set, and `Member kind "hero", requires "heading"` lines for a table of them.
- **Rules.** A rule the plain phrases cover reads as a sentence (`the title is not empty`, `the
  copies is at least 1`). Any other rule is written `this is true: <expression>`, in the same
  expression language the Ruby form uses. `Rule` on an aggregate, `Precondition` for a named check the
  aggregate keeps, `Afterwards` for what must hold once a command has run.
- **What a command does to the thing.** `is set to …` (a value, `the <argument>`, `what the <field>
  was` or `the result of <expression>`), `goes up by`, `goes down by`, `is multiplied by`,
  `is removed from`, `is kept between 1 and 9`, `a row is added to the <list> with <field> from the
  <argument>, <field> as <value>`, `the <entity> is told to <command> with …` and `<Event> is
  corrected with …`. `It can only happen from open and frozen` limits the states it works from, and
  `It takes:` lists arguments of its own.
- **Queries and reports.** `Where the balance is at least the floor` compares with `is`, `is not`,
  `is more than`, `is at least`, `is less than`, `is at most`, `contains` or `is one of`, against
  quoted text, a number, a word or `the <argument>`. A query can say `Limited to 20`, `Skipping the
  first 5`, where empty values come, who may see it and what it returns. A report `includes` or is
  `about` aggregates, `groups by`, `counts`, `adds up`, `averages` or finds the lowest, highest or
  median.
- **Processes.** A `Process:` says what it is matched up by, when it starts and ends, and each
  step: `When TransferRequested is announced and it is requested, it moves to awaiting_credit`,
  then `Then the account is told to debit with number from the source`, and `If that is refused,
  …` for what undoes it.
- **Policies.** Besides `Whenever … is announced`, a policy can wait for what the outside
  announces (`Whenever the outside announces PaymentReceived`), run for each row a query answers
  (`For each live for account of the card`), act `Only when …`, pass a value on (`With the turn as
  "black"`), cross into another domain and expect nobody to receive it.

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

An examples file sits beside the bluebook it is about and has the same name, with the extension
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
  A command several roles may run is written `Who: Customer or Sales Rep`, and an example refuses
  a caller with none of them: `Then it is refused because only a Customer or Sales Rep may do it`.
- `drafts a page with …` makes one; `publishes it` acts on the page made earlier in the example.
- A command named by several words reads as its first word and the rest. `Create Pizza` makes one
  with `creates a pizza with …`, and `Add Topping` acts on the order made earlier with
  `adds a topping to it with …`. The verb may be written in its base form (`create`, `add`) or its
  third-person form (`creates`, `adds`). A command that makes a record is not written with `to it`,
  and one that acts on a record always is. A step that matches nothing is refused with the
  wordings that would have worked, and two commands that read alike are refused by name.
- `tries to` is how a step that should be refused reads, and the example then has to say why. The
  reason is the rule's own sentence, copied from the `Rule` or `Given`.
- An example has one `When`. A `Where:` table runs it once per row.
- Every name is checked against the domain, and a wrong one is refused with the names that would
  have worked.
- A domain that asks the outside needs a port to ask it through before it can run at all. Put a
  Memory-bound hecksagon beside the examples named `<name>_behaviors.hecksagon` (Pizzas keeps one,
  `examples/pizzas/pizzas_behaviors.hecksagon`); it is booted with the bluebook. Nothing answers
  the ask in an example, and the runtime refuses it, so an example of such a command is best
  about the order's state (`Then the order is submitted`) rather than the list of events.

Run them like any behaviors file: `hecks run_behaviors target=page.examples`, or give a directory
and every `.behaviors` and `.examples` file under it runs.

## Tools

| | |
|---|---|
| `hecks-parse format --bluebook Cms page.bluebook` | prints the file in the one canonical wording; works on a Ruby-form file too |
| `hecks-parse render --bluebook Cms page.bluebook` | prints the Ruby-form text for the same bluebook |
| `hecks-parse examples --bluebook Cms --examples page.examples page.bluebook` | prints the `.behaviors` text the examples run as |
| `hecks-lsp` | squiggles at the column a sentence went wrong, and offers the sentences legal at the cursor |
| `hecks language_run.project_phrase_table --confirm` | regenerates the parser's table of sentences from the `Sentence` bluebook |

`hecks-parse` is built with `cargo build --release --manifest-path rust/parser/Cargo.toml`; a
sentence file needs it to boot, found at `HECKS_PARSE_BIN`, in `rust/parser/target/`, or on the
`PATH`.

## What it cannot say yet

A `.hecksagon` beside a bluebook written as sentences is refused by name. So are:

- a policy that triggers a command no bluebook in the file declares, and a lifecycle transition
  that names a command nobody declares, because a sentence file has to make sense on its own;
- a report that pages each of several included aggregates separately (`on:` a head);
- the facts a command or query asks the runtime to supply (`needs`), a query's `cursor`, a command
  argument whose type or default differs from the field it names, and a quote inside a quoted
  value;
- in an example step, a value for a value object that holds more than one field (a pizza with a
  price and a size), or whose one field is not called `value` (a price in cents). Such a step is
  refused with `holds more than one value; examples can only give a single value so far`, so a
  command that needs one cannot be run by an example yet.

Anything the formatter cannot write is refused with the name of what it could not say, never
dropped, so a bluebook that formats always reads back as the same thing. Comments are the one
exception: the IR holds none, so a format drops them.
