# Sentence contract

**Status:** Draft, governed by ADR 0159.

The contract is what a sentence reader must do to be a valid implementation of plain-sentence
`.bluebook` files. Hecks owns it. The reader lives in its own repository and pins a contract
version.

## Inputs and outputs

- **Input:** a file whose first line is `Domain: <name>`, read as sentences. Indented with spaces.
  A line starting with `#` is a comment.
- **Output (success):** the chapter's IR as `ir.json`, the same shape the Ruby runtime produces.
- **Output (refusal):** `file:line:column: message`, naming the line and column the sentence stopped
  fitting at, and the nearest phrase rows. A refusal is never a silent skip.
- **Output (format):** the chapter as canonical sentences. Formatting then parsing returns the same
  IR, and formatting twice changes nothing.

## Phrase table

`contract/phrases.json` is generated from the `Sentence` chapter
(`lib/hecks/language/sentence/sentence.bluebook`). Each row:

| field      | meaning                                                              |
|------------|----------------------------------------------------------------------|
| `id`       | the phrase's name                                                    |
| `context`  | the block it is legal in                                             |
| `pattern`  | literal words, `(a\|an)` alternatives, `{slot:kind}` fill-ins       |
| `opens`    | the block it opens, if any                                           |
| `status`   | only an admitted phrase reaches the reader                           |

Slot kinds: `words`, `word`, `text`, `int`, `list`, `rest`, `path`, `event`. The reader must
accept exactly the slot kinds in this list and refuse any other.

The reader carries no grammar of its own. A sentence matching no row is refused.

## Sentence to IR mapping

The mapping is the contract's semantic core. A reader must produce, for each sentence form below,
the IR node shown.

| Sentence | IR |
|---|---|
| `Domain: X` and an indented paragraph | domain, `vision` |
| `Aggregate: X` and a paragraph | aggregate, `description` |
| `A page is identified by its slug.` | `identified_by` |
| `It has:` lines (`a slug: page slug`, `…, optional`) | attributes |
| `A page slug has a value: text.` | a single-value value object |
| `Rule "…" holds when the value is not empty` | invariant (`!value.to_s.empty?`) |
| `Lifecycle: status, starting as draft` and `Publish moves a page from draft to published` | lifecycle, transitions |
| `Command: X`, `Goal:`, `Who:`, `It acts on an existing page`, `When a slug is given`, `Given "…" holds when the status is draft`, `Then the slug is set`, `And PageDrafted is announced` | command, `role`, `goal`, `reference_to`, attributes, given, `sets`, `emits` |
| `Query: X`, `Where the status is draft`, `Ordered by slug.value, ascending` | query |
| `Policy: X`, `Whenever E is announced [by an order]`, `Then C runs [with the x]` or `Then N is asked [with the x]` | policy with `trigger` or `ask` |
| `Who: A or B` | `role` (first) and `roles`, only when more than one role is named |

A rule or given is `Rule "<description>" holds when <condition>`: the description and the
checkable condition both survive into the IR.

## Conformance

The corpus is `spec/fixtures/sentence/`. Each case is a sentence file and the IR it must lower to,
byte for byte. The reader passes a case when its output equals the IR exactly, or when it refuses
by naming the construct it has no phrase for. A refusal that drops a construct fails.

The known refusals are listed in `spec/sentence_coverage_spec.rb`. An entry the reader now
handles fails that spec, so the list only shrinks.

## Versioning

- The contract carries a version (`MAJOR.MINOR.PATCH`) in `contract/version.json`.
- A phrase or mapping change bumps the minor version; a removed phrase or changed IR shape bumps
  the major version.
- Hecks pins the reader to a contract version in its gate. A reader that does not match the pinned
  version fails the conformance run.
