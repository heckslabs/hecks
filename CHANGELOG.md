# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Dates are when a change landed on `main`, not when this file was written.
Entries below are grouped by theme, not itemized commit-by-commit; see
`git log` for the full history.

## [Unreleased]

### Changed

- **Breaking: doors are driving adapters (ADR 0103).** `Hecks::Doors` is `Hecks::Adapters::Driving` and lives in `lib/hecks/adapters/driving/`, beside the GitHub webhook receiver: `RubyDoor` is `Driving::Ruby`, `CliDoor` is `Driving::Cli`, `JsonDoor` is `Driving::Json`, `McpDoor` is `Driving::Mcp` and `McpDoorScope` is `Driving::McpScope`. `install_doors:` on `boot`, `boot_files` and `boot_described` is `install_driving:`; the old keyword is refused as unknown. The MCP server's scope variables are `HECKS_SERVER_TOOLS`, `HECKS_SERVER_DOMAINS` and `HECKS_SERVER_COMMANDS`, and a `HECKS_DOOR_*` variable is refused by name rather than ignored, so a stale spawner fails instead of starting an unrestricted server. The `.mcp.json` server `hecks-door` is `hecks-mcp`. The Custodian's `Door` aggregate is `Launch`, so `hecks door.serve_mcp`, `door.project_cli`, `door.init` and `door.interview` are `launch.serve_mcp`, `launch.project_cli`, `launch.init` and `launch.interview`. The policy and saga interpreters take `dispatcher:` where they took `door:`.
- **Behavior change: the Rust host's era mint now refuses a stored value that dispatch refuses.** A stored row whose value object holds a value outside its closed set (an inline `one_of:`, a type-position `one_of(...)`, a `member` table) or outside a set named by `admits:`, a name the value object does not declare, or a required field left out passed the mint's Layer 1 audit before and is now refused at the next era mint, in the words dispatch uses (`Band admits "small", "medium", "large" — got "huge"`). To find the rows, rehearse the mint on a copy of the data (`mint_harness`, or a committed-approval rehearsal): the audit refuses before anything is minted, so a refusal leaves no half-born era, and it names every offending record, not the first, as `cannot mint era N of D: the audit refused —` followed by one `Aggregate#id: ...` line each. `hecks era.audit_translation` is the Ruby audit and still trusts stored state, so it does not name them. The packages declare closed sets at `analytics` (`Provider`, `TargetType`, `DeviceClass`), `payments` (`Processor`, `PaymentType`), `journal`, `lineage`, `checkout`, `sessions`, `telemetry`, `operations` and `presentation`, and a site's own bluebook can declare more; none declares `admits:`. The audit also reads a required list left out as empty, a required list stored as `null` as no members, and a required value-object slot stored as `null` as built from no fields, as dispatch does, so those no longer refuse a mint that an invariant reading the list used to fail with `could not be checked`.

### Added

- **The generated content editor edits pages of a fixed structure (ADR 0095, addendum).** A working copy that is a value object, or a list of them, is a draft like a body is (`SaveDraft`, `PublishDraft`, `DiscardDraft` found by shape): the form starts from the live content, saves as a whole by itself, and the record's page says `Changes not published yet`. A value object with a media key and an `alt` is a picture wherever it sits, with the picker and the description required with its error beside the field; a text a rule bounds above 200 characters (`summary.to_s.size <= 600`) is a writing box with its limit; a list whose members hold a body or a picture is cards made from a template, nested one level (a list in a list), with the limits its holder's invariants give shown beside it, and a read-only page of nested values reads as named parts. A refusal about a nested value object marks the card and the field it is about, by the value it echoes. A group left blank is left out, and one filled in part is sent whole so the domain words the refusal. Added to the fixture `spec/fixtures/site/editor_fixed_pages`.

- **`driven_by` admits a driving adapter in a hecksagon (ADR 0103).** `driven_by "Mcp"` names an adapter (`Ruby`, `Cli`, `Json` or `Mcp`) that may reach the domain. A domain that declares none stays open to all four; once it declares any, each adapter it left out refuses it: `Hecks.boot` refuses to install the Ruby module surface, the launcher answers the refusal with status 1, `Driving::Json.aggregate` raises `Admission::Refused`, and the MCP server answers the call with an error. Boot refuses a name no adapter answers to. The Rust parser reads the word and drops it; `ir.json` carries nothing for it. The pizzas example declares all four.
- **`POST /registrations` can close ahead of an event's start.** An Event row that carries both `starts_at` and `registration_cutoff_hours` (Unix seconds and whole hours, each a bare number or a `{"value": N}` value object) is refused with `422` `registration has closed for this event` once now plus the cutoff passes the start; exactly at the cutoff is still open, and a missing, `null` or unreadable field means no cutoff. The check sits after the status check and before the seat check, so a refusal writes nothing. The route takes its clock through a small `registrations_route_at` seam so a test can fix the time.

- **The generated content editor edits an ordered list of mixed blocks (ADR 0095, addendum).** A `list_of` value object whose `kind` is a closed set (or a text part restricted to a literal list) is drawn as cards: a kind badge and one line each, move up and down by keyboard with the result announced, removal after a question, a form with only the slots the kind uses, buttons and entries as nested groups, a picture's key and description together with the picker, and a rich-text body that gets its writing surface when its card is opened. Which slots a kind uses is read from a declared table of rows (`kind`, `requires`, `uses`) in the aggregate, and with none every slot is shown. The working copy (`SaveDraft`, `PublishDraft`, `DiscardDraft`) and its autosave work for a list, not only a body, and a refusal is mapped to the card and slot that caused it. A refused save that a host answered with an unset slot echoed as `null` is no longer shown as saved.

- **A policy can ask: `ask :check, with: { run: :run }` (ADR 0100).** A policy says what it needs done by name and the hecksagon says which port operation answers, so a bluebook stops spelling `Aggregate::Port::Operation`. Boot resolves an `ask` by the event's aggregate and the ask's name against that aggregate's declared `asks`, and dispatches exactly what the port-naming `trigger` it replaces did, `with:` included. When one aggregate declares the same ask on two ports, the hecksagon picks with `Domain::Aggregate.ask_via "Check", port: "..."` and boot refuses the tie otherwise. An `ask` no declared ask answers is a boot refusal and a `model_check` error; a declared ask no policy reaches and a `trigger` that names a port operation are warnings. The IR policy row carries `ask` in place of `trigger_command` (and no `ask` key on any other row, so existing IR does not move); the Rust parser reads `ask`, and the generated policy table resolves it from the same IR. `spec/corpus/asks` freezes the resolved targets and both runtimes are held to them, and `spec/ask_migration_spec.rb` refuses a new port-naming trigger in a migrated file. `trigger` is unchanged. Wave 1 moved the 18 triggers of `tooling.bluebook`; 115 remain across `codebase`, `deploy`, `custodian`, `tickets`, `site` and `quality_control`.

- **A command can compute a value: `sets :refund_cents, to: paid_cents * late_percent / 100`.** The expression ledger admits `-`, `*` and `/` beside `+` (inner grammar, `top_level_split`, so they read like `+`), and `sets` takes arithmetic as its `to:` source. `+ - * /` read left to right, `* /` bind tighter than `+ -`, and parentheses group (a group reads as what it wraps). A bare name is a command argument, or else a field of the record as it stood before the command, so a computed field never sees another field the same command writes; a single-field value object operand reads as its scalar, and the target's single-field value object wraps the result as `sets :x, to: :y` already does. Integers are signed 64-bit: `/` is floor division (`10801 * 50 / 100` is `5400`, `-7 / 2` is `-4`), and a zero divisor or a result outside 64 bits is a fault (`divided by 0`, `multiplication overflowed: ...`), never a crash or a wrapped number; floats divide as floats and a non-finite result is a fault. The grammar reads a `-` as binary only after an operand, so `a - -5` and a leading `-5` still work. The Rust parser, kernel and generator do the same: the IR carries a computed source as `{kind: "expression", text:, ast:}`, the generated command evaluates it through the kernel's `interpret`, and a target that is not a single-field Integer or Float value object is skipped as not generated yet. The frozen conformance fixture `computed_sets` holds both runtimes to the same answers; the grammar corpus pins the new levels. An operand can be a dotted path into a value object, on the command's arguments or the record's fields (`to: charged.cents * late_percent.value / 100`, `to: price.cents - discount.cents`), read by the same path a `given` reads; a path that names an undeclared field, runs through a list or a reference, or stops on a multi-field value object is refused when the bluebook loads, with the path in the message. Planned, not in this change: `increment:` and `decrement:` are expected to be retired into this form on the next major release; they work unchanged until then.
- **A capability can name a word and a field (ADR 0099).** `Capabilities::CONTRACTS` gains two optional kinds, `:text` (the string `default:` of an attribute) and `:attribute` (the attribute's own name). `provides "payments"` accepts `lapse_reason: "Payment.lapse_reason"` and `provides "registrations"` accepts `registered_at: "Registration.requested_at"`; the exported facts carry the word and the name, and the Rust host records that reason when a checkout hold lapses and reads the registration timestamp by that name instead of guessing among four, with labelled legacy defaults and one warning each. The processor name and modes stay in the Stripe adapter (a test holds them to the domain's lists), and the mock mailer's refusal vocabulary is adapter-side test vocabulary that nothing in the domain names, so it stays in the two mocks.

- **A capability can name a duration (ADR 0098).** `Capabilities::CONTRACTS` gains an optional `:duration` kind, spelled `Aggregate.attribute`, that resolves to the whole-seconds `default:` of that attribute (a bare integer or the `{ value: N }` fill of a one-field value object); no new word. `provides "newsletter"` accepts `confirm_window:` and `unsubscribe_window:`, and a new `checkout` capability accepts `webhook_tolerance:` and `session_hold:`. The exported `newsletter` and `checkout` facts carry the seconds, and the Rust host reads the signed-link lifetimes, the webhook freshness window and the session hold from them instead of constants, with labelled legacy defaults and one warning per window. The processor's 30-minute minimum session expiry stays an adapter-side clamp in the host.

- **A capability can name a lifecycle mark (ADR 0097, step 3).** `provides "payments"` accepts an optional `holds_seat: "Payment.holds_seat"` (spelled `Aggregate.mark_name`); `Capabilities::CONTRACTS` gains a `:mark` kind, which is optional, and a chapter that names a mark its aggregate's lifecycle does not declare is refused. The exported `payments` fact gains `holds_seat: [states]` only when declared, so existing IR is unchanged, and the Rust host reads the seat-holding states from it instead of the lifecycle it cannot see.

- **The `newsletter` capability names its subscriber marks (ADR 0097, step 3).** `provides "newsletter"` accepts optional `awaiting_confirmation: "Subscriber.awaiting_confirmation"`, `receives_issues: "Subscriber.receives_issues"` and `left: "Subscriber.left"`, each a `:mark` over the subscriber lifecycle. The exported `newsletter` fact carries the declared state lists, and the Rust host's subscribe, confirm, unsubscribe and issue-send routes read them instead of the strings `pending`, `confirmed` and `unsubscribed`. A chapter that omits a mark gets the host's labelled legacy default and one warning.

- **The `privacy` and `subject_keys` capabilities replace the literal chapter name "Privacy".** `provides "privacy"` names the chapter's `mark_sensitive` command and `markings_for` query, and `provides "subject_keys"` its `key_for` query and `shred` command; the Privacy chapter declares both. Boot's seeding of `mark_sensitive` facts, a handle's masking of a marked read and `Ports::KeyVault.shred!` resolve the verbs through `Registry#provider_of` instead of dispatching `Privacy::...` by name, so a chapter that provides them under another name works the same.

### Changed

- **A `for_each` policy's `with:` can name the fan-out row's own fields.** `with: { refunded: :charged }` used to resolve only against the event payload, the emitter's identity and the row's id, so a row's `charged` could not be read. The projection's source is now the row's fields, then the emitter identity, then the payload, so a payload value is never overridden and the row key still carries the row's id. A policy without `with:` forwards what it did before, with no row fields added. The build-time `with:` check now reads a `for_each` policy's names against the event's shape and the row's names (the query aggregate's attributes, lifecycle field, projected fields, `:id` and the row key) and refuses any other name, where it used to skip a `for_each` source; a query whose aggregate is not in the chapter stays unchecked. The Rust kernel offers the same row fields in the same order. The frozen conformance fixture `fan_out_row_fields` holds both runtimes to it.
- **A `projects` field may read a single-field value object.** `Booking.projects :starts_at, from: :"event.starts_at"` was refused at build with "which is not a scalar" when `Event.starts_at` was typed `StartsAt { value: Integer }`, the only shape the language allows for a lone scalar on an aggregate. A value object with exactly one scalar attribute is now projectable, and the projecting aggregate holds the unwrapped scalar (`123`, not `{ value: 123 }`), seeded on save and refreshed by the sweep. A multi-field value object, a reference and a list are still refused with the same message. The Rust kernel does the same and keeps the remote field's type: a projected pseudo-attribute is typed from the field it reads (Integer, Float, String; a single-field value object resolves to its one attribute), `seeded_projections` hands back a `Value`, and `SetProjectedField` narrows it to that type, so an Integer projection is seeded as an integer rather than dropped. The generated setter's signature changes (`Option<Value>`), so every domain's committed output is regenerated. A Boolean remote field has no Rust column type in the generator yet, so it is not covered. The frozen conformance fixture `projected_single_field_value_object` holds both runtimes to the same answer. ADR 0025 records it.
- **`--wait` reads the failure states from the lifecycle, not the world (ADR 0097).** The Hecks, Deploy, Site, Codebase, QualityControl and other chapters mark each lifecycle's failing states with `mark :failure, "flagged", ...`, and `Doors::LauncherOptions.failed?` reads that mark. The `failure_states` setting is gone from `hecks.world`, `deploy.world` and `site.world`, and `spec/hecks_launcher_failure_states_spec.rb` now asserts every state named like a failure is marked on its own lifecycle. A client whose world still lists `failure_states` has the key ignored: mark the lifecycle instead. The chapter-name checks for `Hecks` in the hecksagon builder and chapter validation stay: they guard the gem's own Ruby module `Hecks`, not a domain fact.
- **The pending release can be named on the `[Unreleased]` heading.** Write `## [Unreleased] - planned 3.11.0` to say which version the accumulating changes will ship as, and drop the suffix when that release is cut. The release checks read only `## [X.Y.Z]` headings, so the suffix changes nothing they do; `spec/changelog_planned_release_spec.rb` pins the shape and that the planned version is later than the latest release. A `planned` state on the `Release` aggregate was weighed and not built: its record lives in memory for one publishing run, and `Tag` creates it, so a planned record would not outlive the process that wrote it.
- **A release needs the owner's approval, written in the bump commit.** The `Lane` row a release is cut from gains `release_trailer` (`Release-Approved-By` on `stable`). `release.yml` now refuses to cut a release, before it tags or pushes anything, unless the commit that set the version has a `Release-Approved-By: <name>` line in its message; after a promotion an unapproved bump releases nothing and says so, so a bump landing on `main` no longer ships by itself. A tag that already stands counts as approved (finishing a half-cut release needs nothing), and `gh workflow run release.yml -f tag=vX.Y.Z -f approved_by=<name>` approves a bump by hand. `hecks publishing_run.publish` judges the same rule as a new given of `PublishingRun`'s `Accept`, read by `Hecks::Release::Approval`.

### Fixed

- **The content editor leaves an optional group with nothing in it out of what it sends, and marks only what a refusal is about.** An optional value object left blank (an empty body, a band with no picture) was sent as an empty value, so a rule that reads `set?` saw a group the person never made; it is now absent, and a group with anything in it is sent whole. A refused save of a nested value object also marked the whole working copy invalid beside the field it named; it marks the field.
- **The Rust mint audit holds a stored value to every constraint dispatch holds an offered one to.** `reference_validate` read `admits` as a list when the IR writes it as `"Aggregate::Set"` (so a declared set was never checked), never read a closed set's `members`, ignored a name a value object does not declare and a required field it left out, and let an integer past signed 64 bits through. It now runs each value object through the checks of `Value::Validation#validate!` in the same order (undeclared names, required fields, closed-set membership, `admits:`, list and scalar shape, `pattern:`, invariants) at every depth and in list members, resolves a value object another aggregate of the chapter declares as Ruby's `value_object_for` does, and fills a value object's defaults and empty required lists before an invariant reads it. `spec/corpus/rust_conformance/attribute_constraints_*.json` pin accepted and refused values for each constraint at the aggregate, one, two and three levels down and inside list members, held to dispatch on both runtimes and to the audit by `spec/rust_host_reference_validate_conformance_spec.rb`.
- **Generated Rust refuses what Ruby refuses for a pattern, a name and a shape.** The Rust kernel enforced a `pattern:` with `^` and `$` as line anchors while Ruby rewrites them to whole-value anchors (`PatternSubset.whole_string`), so `"abc\n"` passed `^[a-z]+$`; generated dispatch now reads them as the whole value (`kernel::pattern::matches_whole`). A `pattern:` on a `list_of(String)` held by a value object was never checked, and is checked per member. A closed-set value object accepted a name it does not declare, and a multi-field closed set refused a non-member with a `TypeMismatch` that named no admitted values; both are worded as Ruby words them (`UnknownArgument`, then `InvariantViolation` quoting the first column). A String field offered a number or a boolean, an Integer past 64 bits, and a list or scalar of the wrong shape on a command argument now carry Ruby's wording (`Write.slugs expects list_of(Stamp)`, not `WriteArgs.slugs: expected ...`). Two divergences remain and are not in the corpus: the Rust JSON reader cannot tell `3.0` from `3`, so an Integer field offered `3.0` is accepted where Ruby refuses it, and a Rust record holds a list as a `Vec`, so a required list offered `null` is stored as empty where Ruby keeps the `nil`.
- **The fuzzer no longer draws NaN or infinity for a Float.** The sequence generator drew them as Float edge cases, but a sequence reaches the Rust kernel as JSON, which cannot write either, so a fuzzed domain with a Float field raised `NaN not allowed in JSON` in the conformance fuzz spec before any runtime ran. It draws signed zero and large and small finite magnitudes instead, and the refusal of a non-finite Float stays pinned by `spec/runtime/numeric_boundary_spec.rb`.
- **`hecks-parse` keeps the closed set a type-position `one_of(...)` inside a value object synthesizes.** `value_object "Frame" do attribute :grade, one_of("a", "b") end` names a type `Grade`; Ruby installs that closed set on the aggregate right after `Frame`, and the Rust parser discarded it, so `hecks-build` emitted Rust that named a `Grade` it never defined. The parser now returns it beside the value object, and the IR of `attribute_constraints_fixture` is the same on both sides.
- **The fuzzer draws a list held by a value object as a list.** `ValueGenerator` drew every attribute of a nested value object as one value, so a `list_of(Cell)` inside a value object arrived as a single object and was refused as a shape error on both sides, never reaching the members' rules. It now draws up to three members, each kept an object (the one-field bare-scalar shorthand stays on the list's own arguments).
- **Generated Rust compiles an optional value object held inside a value object.** `attribute :note, Note, optional: true` on a value object (or on a list member's value object) emitted `self.note.check_invariants()` on an `Option<Note>`, which did not compile. The nested value object's own invariants now run only when it is present, as Ruby validates only what it is given; an optional list of value objects checks each member the same way. `spec/corpus/rust_conformance/optional_nested_value_object_explicit.json` and `optional_nested_value_object_absent.json` hold both runtimes to the same answers for a slot present, sent as null and left out, through a value object, a list member and two levels down. A fixture may set `rust_echoes_absent_slots_as_null`: Ruby keeps an absent nested slot absent and a Rust record echoes it as null, so that one fixture is compared with null-valued keys dropped from both sides.
- **The Rust mint audit reads an absent optional slot as unset, as Ruby does.** A stored value object that left out an optional slot (a span with no `href`, a block with no `align`) was refused at mint with `cannot resolve "href" — no such attribute or argument` whenever one of its invariants read the slot. `reference_validate` now fills each declared optional slot a stored value lacks with null before evaluating its invariants, as the Ruby validator does, so `.set?`, `.unset?`, `.nil?`, a comparison and a path through an absent value object answer for it. A name the value object does not declare is still refused. `spec/rust_host_reference_validate_conformance_spec.rb` hands the Rust audit every value the conformance fixtures write and holds its accept or refuse, and the rule it names, to Ruby's.

- **A Rust `for_each` query is lent the emitting record's identity, as Ruby lends it.** Ruby fills a query argument named for an identity head of the emitting aggregate from the event's record id when the payload lacks it. The Rust kernel ran the query on the payload alone, so a command that only references its own record (`reference_to Registration`, an empty payload) gave `where(registration_id: :registration_id)` nothing and the fan-out matched no rows, silently. Rust now lends the id under the aggregate's single identity head when the query reads that name and the payload lacks it, never overriding a payload value; an aggregate with a composite identity has no single head in the generated table and is lent nothing. The frozen conformance fixture `for_each_identity_lent_to_query` holds both runtimes to it.
- **The generated editor's picture picker fits a phone and stays clear of the action bar.** At 375 pixels wide the picker was taller than the window and lay across the page's sticky action bar, so it had to be scrolled with the page. It now stands in the window (`fixed`, centred, never wider than the window less the notch), is as tall as the space between the app bar and the action bar (read from the bar's top edge and the visual viewport, so the on-screen keyboard counts), scrolls inside itself, and keeps focus where it was. The action bar clears the home indicator, and file inputs get the 44 pixel target the other controls have. This is a generator and template decision; the bluebook declares neither.
- **A success notice no longer says a word twice.** Scheduling left "Scheduled scheduled action." because the aggregate's name was appended to the past-tense verb. The notice now drops a noun word that is the verb again ("Scheduled action."), and the past tense covers more irregular and doubled-consonant verbs and their prefixed forms ("Begun post.", "Rewritten", "Logged"). `done` is generated from the command's name because a command's `goal` is a description, not a sentence in the past tense; `spec/site_cms_editor_words_spec.rb` runs a table of verbs and nouns.
- **A Rust host answers a declared query that has no `where`.** The generator skipped such a query, so the host refused it and a caller saw silence; a query with no `where` now answers every record, ordered and bounded as declared (`order_by`, `limit`, `offset`, `nulls`), and a record whose ordered field is unset sorts where Ruby puts it. A query that takes arguments yet filters, orders and bounds nothing is still not generated, because Ruby refuses it at boot too. The refusal for a query the host does not generate no longer lists `order_by`, `limit`, `authorize` and `nulls` as unsupported; they are not.
- **A host question that names an attached chapter keeps that chapter.** `Chapter::Aggregate.Query` was re-qualified with the host's own domain name, so a chapter's query was looked up in a table that does not hold it. The question now goes to the chapter it names.
- **`.strip` in an invariant or a `given` evaluates the same in Ruby and Rust.** It was not an operator at all: it parsed as a lookup, which Ruby and Rust both read as nothing, so `value.to_s.strip.empty?` failed with "empty? expects a list or string, got nil" at the first value offered. `.strip`, `.lstrip` and `.rstrip` are now admitted text operators (the ledger, the projection, the kernel, the host's expression reader and `hecks-parse`), trim Ruby's whitespace set (null, tab, line feed, vertical tab, form feed, carriage return, space) and never a Unicode space, and refuse a receiver that is not a string. A refusal that echoes an offered form feed or backspace writes it as Ruby's `JSON.generate` does (`\f`, `\b`).
- **A committed `oidc.json` compares equal under any json release.** `JSON.pretty_generate` spells an empty list `[]` in some json releases and `[` newline newline `]` in others (2.7.2, the version `Gemfile.lock` pins, among them), so `lib/hecks/deploy/oidc.json`, written where the list is `[]`, read as drifted in CI. `Hecks::Projections::OIDC.render` now writes the manifest with an empty list as `[]`, and both `hecks deploy oidc_manifest.project_oidc` and `spec/oidc_manifest_spec.rb` use it, so no committed manifest changes.
- **`site_projection.check_roles` no longer faults when its probe is the first thing loaded.** `Hecks::Projections::Site::RoleProbe` calls `Bluebook::Synthesizer` without requiring it, so `spec/site_roles_spec.rb` raised `NameError` whenever no earlier file in the run had loaded it (alone, or in CI's shard 3). The probe now requires the synthesizer, and `Bluebook::Synthesizer` requires `Bluebook::Attribute`, so the file loads standalone.
- **The Rust host answers a declared query from a caller on the same machine.** `{"query": ...}` was missing from the bodies the host reads as its internal protocol, so a loopback caller was redirected to the login page instead of getting rows; the generated editor's picture picker and any list built on a query failed against a real host. The query body is now recognised beside `read` and `verb`.
- **The generated editor shows a host's silence as a refusal, not an empty list.** A declared query the host does not generate answered with no entry, which was read as no rows: a view tab, a picker and the picture listing showed nothing while the records were there. It is a refusal now (the picture listing falls back to reading the pictures).
- **A line break in a generated editor's body no longer grows each time the body is saved.** A browser sends CR LF for a line break in a form field; it was stored as is and read back as two breaks. The form reader keeps one LF.
- **The generated editor on a phone and for a keyboard.** The preview drawer takes focus when it opens, keeps Tab inside it, and has a close button (it had a label no key could reach); a body shown on a page starts its headings at h3 under the page's h1 and section h2; the view tabs are plain links, not an ARIA tab list that was never implemented; the inactive tab reaches 4.5:1 in the light theme; controls are 44 pixels on a phone or touch screen; the writing surface's toolbar scrolls on one row instead of filling the screen, and a fieldset no longer widens the page; a domain that does not answer, or a chapter closed to a role, says so in its heading rather than "Not found".

## [3.10.0] - 2026-10-07

A minor release: `hecks deploy handover.clear` empties a domain's deployment settings for a client handoff, the generated content editor gains a rich-text body and pictures, `@hecks/client` can ask a host's queries, and two Rust host compile faults are fixed.

### Fixed

- **A value object's required list left out reads as an empty list in Ruby, as it already did in Rust.** A required argument left empty (`body: null`), or an object offered without its list, built `{}` in Ruby and `{"blocks": []}` in Rust, so the Rust conformance fuzzer diverged on the optional-value-object fixture and `main` went red. Ruby now fills a required list the offer lacks with `[]`; an optional list stays absent and an explicitly offered list is kept as offered. A corpus case pins `null`, `{}` and `{"blocks": []}` to the same stored and emitted shape.
- **A Rust host compiles when an aggregate is named `Metadata`, `Registry` or `Merged`.** Each aggregate becomes a module named for it downcased, beside the chapter's own `metadata`, `registry` and `merged` modules, so such an aggregate declared the module twice (`E0428`) and its file overwrote the chapter's. The generator now gives an aggregate named for one of those the module `metadata_aggregate`, `registry_aggregate` or `merged_aggregate` (`naming::aggregate_module`); every other aggregate keeps its downcased name, so no committed generated output changes. A fixture domain naming all three is part of the corpus and the Rust conformance run.
- **A Rust host compiles when a command copies one optional value-object attribute into another field of the same record.** `sets :body, to: state(:draft_body)` generated `record.body = Some(pre.draft_body.clone())`, where `pre.draft_body` is already an `Option<Body>` (`E0308`, "expected `Body`, found `Option<Body>`"); a state source now counts as optional when the record holds it as an `Option`, as an argument source already did. The Rust kernel also reads `.set?` and `.unset?` on a nested object (an optional value-object attribute) as present or absent, where it faulted with "resolved to an object, not a scalar" and so refused every command whose `given` tested such an attribute. A fixture with a body, an optional draft of it, and nested lists of value objects (blocks of spans of marks, with items) is held to the same frozen result by Ruby and Rust.

### Added

- **The generated editor works on a record as one thing (ADR 0095 addendum).** On a record's page, an aggregate whose identity is a `<kind>:<slug>` key of this record's kind is a panel: a document's text read-only with an Edit link, a gallery as a strip of thumbnails, a metadata record as its fields, or an empty state that opens the creating form with the key filled; saving returns to the record with a notice. An aggregate of scheduled actions (a subject key, a closed-set action, a due moment, a lifecycle ending in two final states) adds a Schedule panel to the records it names, with reschedule, cancel behind a dialog and the outcome of ended actions, and a Scheduled screen of every pending action; the editor never runs an action. The `Editor` row takes `preview` (a URL template with `{key}`, `{kind}`, `{slug}`, `{id}`, refused unless an http(s) address or a path with known placeholders), which adds a Preview button opening the page in a side drawer with phone, tablet and desktop widths, a sandboxed frame, refresh after a save, and the preview's origin as the only `frame-src`. An aggregate that keeps `draft_<x>` beside `<x>` is written as a draft: the body autosaves after five seconds idle and on blur with a status line, warns before leaving unsaved changes, and publishes or discards the draft behind a confirmation. A value object that declares a closed set is a select. A record's activity is not shown: the host exposes no per-instance history.
- **One editor can span several chapters, pick related records, page long lists and edit dates (ADR 0095 addendum).** The `Editor` row's `chapter` takes several names (`Press, Library`): the navigation and the overview group the aggregates under a heading for each chapter, each aggregate is addressed by its chapter (`<base_path>/<Chapter>/<Aggregate>`), verbs are sent as `Chapter::Aggregate.Verb`, and two aggregates of one name in different chapters stay two. `chapter_roles` (`Library=Admin;Other=Owner`) limits a chapter to some roles, `page_size` (default 25) sets a list's page, and `skip` takes `Chapter::Name`. An attribute that names another aggregate's instance is offered as a choice, found from the bluebook's own declarations (a `reference_to`, a value object `<Stem>Ref` whose stem is another aggregate's identity type or name, a picture `Ref`, and a `<kind>:<slug>` key stated by an attribute's `pattern`), with the options from the target's own listing query, a strict key checked before the command is sent. Lists are paged, searched (identity and title) and filtered by lifecycle state on the server through the address (`_page`, `_q`, `_status`), remember the last filters for the tab, and one read serves a page and its navigation counts. An integer named for a date (`_on`, `_at`, `epoch`) is a native date or date-and-time input in the person's time zone, stored as seconds, and shown with how far away it is. Creating forms have "Save and add another". Single-chapter editors keep their schema and addresses.
- **The generated editor has a design system, an app shell and a writing surface from libraries (ADR 0095 addendum).** The pages are server-rendered HTML with Tailwind CSS 4 and daisyUI 5 classes, built by `npm run build` into `dist/editor.css` and `dist/editor.js` (the generated sources stay a pure function of the chapter and the row; nothing built is committed; before a build the pages still work, unstyled). The `Editor` row takes three optional settings: `brand` (the product name in the header, default the domain's name), `accent` (a six-digit hex colour, refused otherwise, from which a light and a dark theme are derived, every text and fill pair moved until it reaches the accessibility contrast ratios) and `logo` (a relative path to a picture the server reads from its own directory). The shell is a navigation drawer with the number each aggregate holds, a header with breadcrumbs, the person and role, a theme button that remembers its choice, and sign-out; lists sort and filter in the browser and say when they are empty; a detail page is a document column with a margin panel for the status and the commands that apply, and a command that takes input has a page of its own. A destructive command (first word `withdraw`, `retire`, `discard`, `delete`, `cancel` or `remove`, or a lifecycle move into a state named for one of them) asks first in a native dialog. A success redirects with a one-shot, signed, one-minute notice cookie ("Published.", the same verb as the button); a refusal marks the input an invariant names and moves focus to it. The rich-text editor is now Tiptap 3 with flat list items (`tiptap-extension-flat-list`), converting to and from the domain's own body in plain, node-tested JavaScript, and the picture picker takes several files with required alt text, a progress bar and a message per file. Pages are sent with a content security policy that allows no inline script or style and no other origin; static files carry ETags and versioned, immutable addresses. The generated `package.json` gains the build and its dependencies, and `src/ui/body_widget.js` and the inline stylesheet are gone.
- **The generated editor's first run against a real host fixed its defects (ADR 0095 addenda).** An optional argument that only clears a field (`sets :draft_body, to: :nothing`) is no longer a form field, so `PublishDraft` and `DiscardDraft` clear the draft, and a command's success is judged by the state that comes back, not by comparing the arguments sent (which reported "did not apply" for a command the host had applied). A refused `given` reads "Not allowed unless <condition>." and an invariant shows the field and rule, not raw JSON. A body not yet set (an unsaved draft) starts from the body the record holds. The widget's link and image forms are in the page, not `window.prompt`. There is a sign-out button and `POST <base_path>/logout`. The generated `package.json` pins `@hecks/client` to this hecks's own version (it was `^3.8.0`, which lacks `query`), so it needs a release that publishes the client with `query`.
- **The `Editor` row takes `media: <chapter>`.** Pictures kept in another chapter of the domain are uploaded, listed and picked by this editor's widget, registered with that chapter's domain. A row without it generates the same `media` entry as before.
- **`hecks deploy handover.clear <domain> [out=<dir>]` empties a domain's `deployed_to` settings so a project can be handed to a client.** It finds every `*.world` under `<domain>/bluebook/` (environment overlays included) and replaces the body of each `deployed_to(...) do ... end` block with one comment naming the settings it held, so the file still loads and shows what to set. The rest of each file is left as it was, a world already cleared is not rewritten, and a domain with no `.world` file is `faulted` with the sentence saying so. With `out=` the cleared copies go to that directory at their paths below `bluebook/` and the originals are left alone. A new `Handover` aggregate in the Deploy chapter records each clearing (`cleared` or `faulted`) behind the `DeployToolchain` port's new `ClearDeployment` ask, and the verb is settled.
- **`project_site --editor=<dir>` generates a content editor from the domain's bluebook (ADR 0095).** A project that declares an `Editor` row (the domain's directory and chapter, where the editor is served, its session cookie, the host's address variable, the login page, the roles) gets a small Node/TypeScript package: a server on node's own `http` with no framework, a `schema.ts` that carries the chapter's aggregates, value objects, lifecycles, commands and queries as one typed constant, and server-rendered pages read from it (a nav of aggregates, a list from a query, a detail page, a form per command). Value-object attributes are nested fieldsets, `list_of` attributes are repeatable rows, lifecycle states are badges, and a refusal is shown inline on the form. The editor signs people in through the site's admin hand-off and checks the host's members list on every request. `--check` covers the files; the domain holds no editor data.
- **The generated editor edits a structured document body with a rich-text widget (ADR 0095 addendum).** An attribute whose value object has a `blocks` list of blocks with `kind` and `spans` (chosen by shape, not name) gets a toolbar and contenteditable surface for paragraphs, headings, quotes, lists with depth, dividers, images by media key, marks, links, alignment and indent. It edits the domain's own tree and posts it as the editor's usual dotted-path fields, with no editor format. `bodyToHtml` and `htmlToBody` are dependency-free plain JavaScript that run in node and the browser, escape everything and allow only path, http(s), mailto and tel addresses; pasted HTML is reduced to what the body holds and the widget says what it reduced. The pages show the body read-only through `bodyToHtml`.
- **The generated editor uploads and picks pictures (ADR 0095 addendum).** When the domain chapter has an aggregate that registers pictures (found by shape: a creating command taking the aggregate's key, alt text and a mime type, optionally width and height), the editor accepts a multipart upload at `<base_path>/media`, refuses anything but JPEG, PNG, WebP, GIF and AVIF (decided by the bytes, never the claimed type; SVG is refused) and anything over the Editor row's `media_max_bytes`, keeps the bytes through a small storage port (`put`, `url`, `read`) with a local-disk adapter under `media_dir`, under a key made from the bytes' SHA-256, and registers the picture with the domain command. The widget's image button opens a picker (upload, drag and drop, registered pictures with thumbnails, required alt text, optional caption) instead of prompts; a chapter with no such aggregate keeps the prompts and gets no upload. Stored pictures are served to signed-in editors only at `<base_path>/media/<key>` with `X-Content-Type-Options: nosniff`.
- **`@hecks/client`: `HostClient#query(name, args?)` and `rowsOf(answer, name?)`.** The host's `/dispatch` already answers `{"query": ..., "args": ...}`; the client now asks it, and `rowsOf` reads the rows of the answer or throws `DomainRefusal` when the host refused the question. `Answer` gains an optional `queries` list. Nothing that was there changes.
- `hecks site site_projection.check_roles <project> url=<local host>` dispatches every command a project declares a role for to a host on this machine with no role and no actor, sending arguments synthesized from the declaration so the host reaches its role gate, and checks the host refuses each as `Unauthorized`. A command whose synthesized arguments the host refuses first is reported as unchecked, not failed. A project's smoke no longer hand-lists which commands need a role.
- `deployed_to("AwsFargate")` takes `host_crate "<directory>"`: the Cargo package the generated Makefile builds `bootstrap` from, an absolute path or one relative to the Makefile's `ROOT`. Without it the Makefile builds `rust/host` as before. The Makefile reads it as `HOST_DIR ?=`, so `make HOST_DIR=<dir>` builds another host without regenerating. This lets a site run a host that installs its own `HostExtension`s (ADR 0094). Only path characters are accepted.

## [3.9.1] - 2026-10-07

A patch release: the Resend webhook's signing secret can live in the secret that already holds the Resend API key.

**Changed: the host reads the Resend webhook's signing secret from the same secret as the API key.** The secret `RESEND_SECRET_ID` names may carry `webhook_secret` beside `api_key`; when it does, the host sets `RESEND_WEBHOOK_SECRET` from it at boot, so `POST /webhooks/resend` needs no new environment variable or task-definition secret. A secret with only `api_key` behaves as before.

## [3.9.0] - 2026-10-06

A minor release: the Rust host records newsletter opens and clicks from Resend's webhook.

**Added: `POST /webhooks/resend` records newsletter opens and clicks.** The commerce extension verifies Resend's Svix signature against `RESEND_WEBHOOK_SECRET` (the endpoint's `whsec_` signing secret; without it the route answers 503), finds the `Delivery` whose stored Resend message id matches the event's `email_id`, and dispatches `Delivery.RecordOpen` or `Delivery.RecordClick`, which keep only the first of each. A repeat, an event type nothing records, and a message the site did not send as a newsletter are all acknowledged with 200 so Resend stops retrying. Resend sends nothing until the domain's open and click tracking is on and a webhook for `email.opened` and `email.clicked` points at the route.

## [3.8.1] - 2026-10-07

A patch release: a generated host compiles when an aggregate has an optional Integer, Float or Boolean attribute, or a list of them. Nothing else changes for a deployed host.

### Added

- `hecks site site_projection.check_site <project> url=<address>` asks a running site what its route table says it must answer, with anonymous requests that change nothing: admin routes refuse, indexable public pages answer 200 with a canonical link, `off` rows and undeclared paths answer 404, redirect rows redirect. A project's smoke no longer needs hand-listed paths for these.

### Fixed

- The Rust generator dereferences a copy scalar it reaches through a reference. The `Fielded` arms and the JSON codec wrote `Value::Int(v)` and `Json::int(v)` inside `as_ref().map(|v| ..)` and `iter().map(|x| ..)`, where the binding is `&i64`, so a host with such an attribute failed to compile (`E0308`, "expected `i64`, found `&i64`"). The first vendored chapter to have one is cms 1.2's `Page.level`, which kept every project that took cms 1.2 or later from building. `naming::deref_scalar` dereferences Integer, Float and Boolean and leaves String to its clone.

## [3.8.0] - 2026-10-06

A minor release: the Rust host can be extended without forking it. Nothing changes for a deployed host; commerce is installed by default.

**Changed: the Rust host is a library and a binary, and extra routes plug in through `HostExtension` (ADR 0094).** `rust/host` builds the `rust_host` library beside the `bootstrap` binary. An extension implements `extension::HostExtension`: `guest_route` answers a request before the account gate, `account_route` after the host's own sign-in routes with the signed-in cookies and the domain IR in hand, `rate_rules` declares the public writes to limit per client (a `RateRule` with its own budget setting), `boot_check` refuses a boot the extension cannot serve, and `boot_secrets` reads the extension's secrets at cold start. `extension::install` registers extensions before the first request; with none installed the host installs commerce, so behavior is unchanged. `rate_limit.rs` no longer names the newsletter and registration paths, and `main.rs` no longer fetches the mail secret or runs the payments boot check itself.

**Changed: commerce is the first extension, in one place.** `web::Commerce` (`web/commerce.rs`) carries the newsletter, payments, registrations and mail routes that `render` and `route` used to name directly, and the newsletter, payments, registrations and payment-connection readers moved out of `ir.rs` into `commerce_ir.rs` beside the code that uses them. ADR 0094 proposes moving that code to the platform; this release is the seam it needs.

### Fixed

- The generated CMS Dockerfile fetches the RDS CA bundle with `ADD --chmod=0644`. A plain `ADD` of a URL leaves the file readable by root only, so the CMS (which runs as `node`) failed at boot with `EACCES` on `rds-global-bundle.pem`.

## [3.7.0] - 2026-10-06

A minor release: sites can share one database instance, and a world can deploy to more than one kind. `deployed_to("AwsBox")` takes `shared_database "<stack>"` and generates the provisioning of the site's own database and login role (the Rust host and the generated CMS boot script now read the database user and port from the secret); `deployed_to("AwsSharedDatabase")` generates the RDS instance they share; `deployed_to("Vercel")` generates a Vercel function's configuration; a world may declare several `deployed_to` kinds and `hecks deploy project` generates each. The `edge` tag has a ruleset of its own, and a required check counts only when GitHub Actions reported it.

**Added: `deployed_to("AwsSharedDatabase")` generates the RDS instance that several sites share (ADR 0092).** The platform's world names the stack (`stack_name`, required, used exactly as given because every site's `shared_database` refers to it) and optionally the class, storage, engine and backup days; `hecks deploy project` writes `rds.yaml`, a `Makefile` and a README. The stack creates no database of its own, leaves the security group's rules to each site's box stack, and gives the bastion's rule its own resource so a stack update cannot revoke a site's. `restore-to-rds.sh` takes a `SCHEMAS=` override and passes it to `verify-copy.sh` (`COMPARE_SCHEMAS`), so the same two scripts copy and compare another database's schemas (an analytics database's `public`, say) as well as the world's.

**Changed: the `edge` tag has a ruleset of its own.** `project_lanes` now projects a tag ruleset (`.github/rulesets/tag-edge.json`) for the tag a guarded lane feeds: it cannot be deleted or pointed at an older commit, no actor bypasses it, and moving it forward (what a promotion does) stays allowed. Before, only `move_tag`'s own check kept `edge` from rewinding. `project_lanes --live` compares and applies it with the lane rulesets.

**Added: `deployed_to("Vercel")` generates a Vercel function's configuration.** `hecks deploy project` writes `vercel.json`, `.vercelignore`, `deploy-vercel.sh` and a `Makefile` for a domain's host as one function; region, memory and duration go through the new `Deploy::VercelTarget.Declare`, and secrets are named and piped on stdin, never written. The host's own Vercel entry point is still to do (ADR 0093).

**Added: a world can declare several `deployed_to` kinds, and `hecks deploy project` generates each.** With more than one block (Vercel beside AwsBox, say) each is written under `<out>/<adapter>/` so their Makefiles do not collide; `--target=<adapter>` writes only that one into `<out>`. A world with one block writes the same files as before.

**Added: an `AwsBox` site can share one RDS instance with other sites, each in its own database with its own login role.** `shared_database "<stack>"` in `deployed_to("AwsBox")` makes the generator write no `rds.yaml`; the Makefile and `deploy-box.sh` read the endpoint and security group from the shared stack and the login from the site's own secret `<stack>/database`, and a new `provision-database.sh` (with `make provision BASTION=i-...`) creates the role (not a superuser), the database it owns, and the secret, idempotently, with `--rotate` for a new password. Settings that size the instance are refused beside it. The Rust host and the generated CMS boot script now read `username` and `port` from the database secret, defaulting to `postgres` on 5432, so a dedicated instance behaves as before. A site without `shared_database` generates the same files as before. ADR 0092 records the decision and the phases (the shared instance's own generator, then moving a client onto it).

**Changed: a required check counts only when GitHub Actions reported it.** `stable`'s ruleset pins each required check to the GitHub Actions app (`integration_id` 15368), the promotion reads only that app's check runs, and `project_lanes --live` names a check GitHub takes from any app when the model pins one. Before, any app with `checks:write` could post a passing check of a required name against a commit. A check of the right name from another app now stands as missing.

## [3.6.0] - 2026-10-06

**Changed: the files that hold `Hecksagon` and `World` are named `hecksagon.rb`.** `lib/hecks/bluebook/hexagon.rb` and `behaviour/hexagon.rb` read as a typo for the classes inside them. The files, the `require_relative` lines and the locals that meant a `Hecksagon` carry the right name; hexagonal-architecture wording in the docs is unchanged.

**Changed: an edit under a consumer tree no longer cools the verdict cache.** The verdict file, and with it the syntax-boot cache, is keyed on the trees the judge runs (not all of `lib/`), so a change under projections, doors, cli, deploy, codemod, bench, fuzzing, quality_control, release or doc leaves the next run warm instead of a cold re-judge.

**Changed: RuboCop also runs `rubocop-performance` and `rubocop-thread_safety`.** The safe Performance corrections are applied across the codebase and ThreadSafety is scoped to `lib/hecks/runtime`; the run is clean.

**Added: agents get RuboCop feedback as they edit.** A PostToolUse hook runs RuboCop on each `.rb` file an agent edits and returns the offense in the same turn. A push of only unguarded lanes still skips the suite and now runs an `unguarded_push` stage (RuboCop, comment style, comment blocks) built from the pre-push checks.

**Added: a box roll saves each container's log before it replaces the container.** Docker deletes a container's `json-file` log with the container, so the `would_refuse_role` lines a role-enforcement shadow run produced were lost at every roll. The generated `deploy-box.sh` now sends the box a read-only step first, over the same SSM path, that writes `docker logs` of every running container to `/var/log/hecks-captures/<container>-<UTC timestamp>.log` (directory mode 750, files 640), keeps the newest 14 per container, skips with a warning under 2 GiB free on `/var/log`, and prints each file's path and size, never its contents. A capture that fails is a warning: the roll goes on and its exit codes are unchanged. `deploy-service.sh` captures only the service it rolls; `SKIP_LOG_CAPTURE=1` skips it. The stack template, user data and logging options are unchanged, so a project picks this up by regenerating and rolling. ADR 0085 decision 14.

**Changed: a late `stable` retries its own promotion, and a promotion that releases nothing calls no registry.** `promote.yml` can now be started by hand or by `gh workflow run`, and a failed `lane-watch` run dispatches it, so a promotion that was dropped is picked up within the hour. `release.yml` gains a `detect` job that reads only GitHub (is the release of the version `stable` carries already published?); the `release` job runs only when it is not, so most promotions make no call to rubygems or npm.

**Changed: a promotion is about the newest certified commit, not the push that started it; releases come from `stable`.** `promotion_run.promote` with no `commit=` now moves `stable` onto the newest commit of `main` (first-parent, 25 back) that every required check passed on and that fast-forwards `stable`, so a dropped, late, or out-of-order Promote run changes nothing and a certified commit is never stranded behind a red or still-running one; `commit=<sha>` still judges exactly that commit. A confirmed run also brings `edge` up to `stable`'s head when `stable` already holds the commit, which repairs a tag a half-finished promotion left behind. `promote.yml` starts only from a successful push of this repository (a fork pull request from a branch named `main` no longer qualifies). `lane-watch` dates a branch merged late by the merge that took it in, not by its oldest commit, and says "a promotion should have run" whenever any recent commit is certified, whatever the head is doing. `release.yml` runs after Promote and releases the commit on `stable` that set the version, and refuses any commit `stable` does not contain, a by-hand run included; a push to `main` no longer starts a release. The pre-push hook writes no CI attestation note for a working tree that differs from HEAD.

**Changed: RuboCop runs at its defaults, with a short list of deliberate overrides and no todo file.** `.rubocop.yml` names each cop the codebase departs from (house style such as double quotes and table-aligned hashes, and structural cases such as `module_function` and the RSpec cops) with its reason, and every other cop runs at the RuboCop default. Every offense the defaults find is fixed, and `.rubocop_todo.yml` is deleted. ADR 0091 records the overrides.

**Changed: `hecks` lists the maintainer's commands only inside a hecks checkout, and points at the attached chapters.** Typed in any other project, `hecks` printed the commands for working on hecks itself (`language_run`, `style_run`, `publishing_run` and the rest). It now lists what a project runs against its own domain, then a `chapters` section with one line each for `hecks deploy`, `governance`, `tenancy`, `site`, `tickets` and `quality_control`. A directory with `hecks.gemspec` beside `lib/`, or any directory below one, gets the maintainer's view as before, with the language's own chapters added. `hecks --maintainer` lists everything anywhere, `HECKS_MAINTAINER=1` or `0` forces the view either way, and nothing is removed: every command still runs and answers `--help`. A world's `launcher` setting names the split with `maintainer:`, `chapters:` and `maintainer_chapters:`; a chapter that names none keeps its help whole.

**Behavior change: the host's `session` cookie now expires.** The host refuses a `session` cookie with no `exp` field or
one in the past, the same as a forged one. Before, a validly signed cookie stayed good until `SESSION_SECRET` changed, so a
stolen cookie never lapsed. The host never issues this cookie (an operator mints it with the secret), so nothing logs out
by itself, but every cookie already minted stops working and must be minted again with an `exp` (Unix seconds); the recipe
in `docs/running-a-rules-service.md` section 7.2 now includes it. The lifetime `session_cookie` stamps is
`auth::SESSION_TTL_SECS` (14 days), the same constant the account cookie uses.

## [3.5.0] - 2026-10-06

A minor release: a project's scaffolding is generated from rows beside its route table. `project_site` writes the admin sign-in for both halves (`admin.ts` for the site, and with `--cms=<dir>` the content system's endpoint, membership check, session strategy and users collection), and with `--root=<dir>` the files at the project's root: `.env.tpl`, the check workflow, the content system's image and boot script, and the files that let the content system drive the domain, read from the domain itself. The deploy scripts keep becoming Deploy-chapter commands (`service_roll.run`, `box_roll.run`, `data_copy.restore` and `verify`, `bluebook_diff.run`, `preview_run.<verb>`, `companion_roll.run`), and a missing-database refusal names the role it needs.

**Added: `project_site root=<dir>` writes the files that let the content system drive the domain, read from the domain itself.** A `Payload` row names the domain and its chapter; for each aggregate with a lifecycle it writes the lifecycle module, a spec (input type, wire form, reader, creating command and lifecycle edges) and a catalogue of Payload fields with the reader that turns a saved document into the input. `PayloadField` rows carry what an editor needs that an attribute's shape cannot say (date pickers, choice lists, uploads, relations, labels). The domain is read, never annotated.

**Added: `project_site root=<dir>` writes the project's root files from rows beside the route table.** `Secrets` and `Env` rows write `.env.tpl` (secrets as 1Password references, never values); a `Ci` row writes the workflow that runs `--check` and the project's test; `Cms` and `BootSecret` rows write the content system's `Dockerfile` and `deploy-aws/boot.mjs`, which resolves its secrets from Secrets Manager before the server starts. Each file is written only when its rows are declared, and `--check` covers them. `docs/site-routes.md` lists the rows.

**Added: `project_site cms=<dir>` writes the content system's half of the admin sign-in from the `Admin` row.** For a Payload project, `--cms=<dir>` writes four files under the directory: the sign-in endpoint that accepts the site's hand-off token and mints an ordinary session, the membership check, the session strategy that asks the host again on every request, and the users collection (no passwords, not creatable over its API). They read the same row as `admin.ts`, so the two halves cannot disagree, and `--check` covers them. A new `cms_base` field (default `/cms`) says where the content system is served, and `sso_target` must be under `<cms_base>/api/`. The membership check now falls back to the host's development secret outside production, as the endpoint already did, instead of refusing every question. `docs/site-routes.md` describes the files.

**Docs and message: the deploy record's database needs a non-superuser role, not just `createdb hecks`.** `hecks deploy smoke_run.run ... --wait` against the default persistent environment fails with `cannot open Hecks: ... PostgresEra's era write-fence is row-level security, and this connection's role "hecks" is a superuser`, because Postgres exempts a superuser from row-level security. The generated `Makefile` and `hosting.mk` message for a database that cannot be opened now names both setup steps, a database and a non-superuser role that owns it, with `HECKS_DATABASE=postgres://<role>@localhost/<db>`; the exit codes and what the target runs are unchanged (regenerate to pick up the text). [ADR 0090](docs/decisions/0090-deploy-scripts-become-commands-on-the-deploy-chapter.md) decision 21 and the wiring guide say a machine whose default `hecks` role is a superuser needs a separate non-superuser role, with an example.

**`hecks deploy bluebook_diff.run`, `preview_run.<verb>` and `companion_roll.run` run a project's last three scripts as commands and record each run, closing ADR 0090.** `bluebook_diff.run <project>` reports which bluebook releases a deploy changes: given `old=` and `new=` (two `package.verify` outputs) it compares them in Ruby, offline; given neither it runs the project's `bluebooks-diff.sh` and classifies its report. It never fails: `unchanged`, `changed` and `unavailable` are all exit 0, and only giving one of `old` and `new` is `flagged`. `preview_run.name`, `.url`, `.list`, `.deploy`, `.destroy` and `.login` run the project's `preview.sh`; the reads need nothing, and the three that write to AWS or read its secrets refuse without `confirm=true` (naming the plan, running nothing), print the plan for `dry_run=true`, and refuse `main` and `master` before anything runs. `companion_roll.run <project> taskdef= [companion=umami]` rolls a second Compose project onto the box with the project's `deploy-<companion>.sh`, with the same refusal and dry run, and ends `rolled`, `planned` or `flagged`. Each wraps the script as it is: a script that ends non-zero is `flagged` with its status and output in the reason (exit 1). The new `CompareBluebooks`, `RunPreview` and `RollCompanion` asks sit behind the `DeployToolchain` port, the verbs are settled, and the specs run stand-in scripts and a stand-in `aws`, never AWS.

**`hecks deploy data_copy.restore` and `data_copy.verify` run a project's data copy as commands and record it, with a refusal that stops an unconfirmed overwrite.** `data_copy.restore <project> bastion= source= source_secret= target= target_secret= [source_db=] [target_db=] [force=true] [confirm=true] [dry_run=true] [skip_verify=true]` runs the generated `restore-to-rds.sh` and `data_copy.verify <project> ...` the generated `verify-copy.sh` (`script=<path>` overrides how the script is found). A restore overwrites the target database's schemas, so it is **refused, as `flagged` with exit 1, unless `confirm=true`**; the reason names the schemas, database and host it would overwrite. `dry_run=true` prints that plan (state `planned`) and runs nothing. Each copy is a `DataCopy` in the Deploy chapter, and a `CopyVerification` joined by policies: a restore that ran is `restored`, a policy requests the comparison under the same run key (unless `skip_verify=true`), and policies on its outcome move the copy to `verified`, `drifted` (the databases differ) or `flagged`, so one command exit covers the whole copy; `data_copy.verify` runs the comparison alone and records the same outcomes. The scripts now end with distinct statuses: `verify-copy.sh` 50 when the databases differ, and `restore-to-rds.sh` 60 (a Postgres client older than 16), 61 (the target already has a schema) and 62 (unexpected restore errors); with `VERIFY_BY_COMMAND=1`, which the command sets, `restore-to-rds.sh` ends after the copy and leaves the comparison to the policy. The generated `Makefile` does not call either script, so no recipe changes. [ADR 0090](docs/decisions/0090-deploy-scripts-become-commands-on-the-deploy-chapter.md) marks both rows built (decisions 11 to 13).

**`hecks deploy service_roll.run` and `box_roll.run` roll a project as commands and record the whole deploy, smoke included; every `make deploy` and `make deploy-service` calls them.** `service_roll.run <project> service=<name> [existing_tag=] [local_image=] [skip_smoke=true]` runs the project's generated `deploy-service.sh`, and `box_roll.run <project> [taskdef=<family[:rev]> | tags="name=tag ..."] [skip_smoke=true]` runs `deploy-box.sh` (`script=<path>` overrides how the script is found). Each records a `ServiceRoll` or `BoxRoll` in the Deploy chapter. A successful roll's policy requests a `SmokeRun` under the same run key, and policies on the smoke's outcome move the roll: `verified` when the smoke passed, `flagged` (with the smoke's reason in `refusal`) when it failed, so one command exit covers the whole deploy. `rolled` alone means no smoke was requested, and the record's `smoke` field says why: `smoke skipped: skip_smoke=true` or `smoke skipped: no smoke script`. A failed roll is `flagged` with the script's status. The scripts now end with distinct statuses instead of 1: `deploy-box.sh` 40 (no instance), 41 (the roll did not succeed), 42 (the box unhealthy after it); `deploy-service.sh` 2 (unknown service), 30 to 38 (a refused step: tag missing from or already in ECR, Compose file unreadable, no instance, no such stack parameter, stack update failed, another parameter changed, image missing from the task definition, no such container) and the box roll's 40 to 42. Run with `SMOKE_BY_COMMAND=1` (which the command sets), `deploy-service.sh` ends after the roll and leaves the smoke to the policy; by hand it still smokes. The generated `Makefile`'s `deploy` runs `box_roll.run` for **every** AwsBox project, with or without `hosting_scripts true` (a project without the smoke script records `smoke skipped: no smoke script`), and the Makefile now defines `HECKS ?= hecks`; `hosting.mk`'s `deploy-service` runs `service_roll.run`. Each deploy is durable in the Hecks database (`HECKS_DATABASE`, default `postgres://hecks@localhost/hecks`). Without the database the target still runs the script (and the smoke) and prints the result, and fails with `Error 24` if everything passed. Regenerate a project's recipe to pick this up. [ADR 0090](docs/decisions/0090-deploy-scripts-become-commands-on-the-deploy-chapter.md) marks both rows built (decisions 8 and 9 are the smoke record and the every-project rule).

**Added: `hecks site site_projection.project_site` writes `admin.ts`, a project's admin sign-in, from an `Admin` row.** A project that serves admin pages from a domain host declares one `member` row of a `value_object "Admin"` beside its route table (the session cookie, the variable that holds the host's address, the login page and the hand-off to the content system), and the tool writes a dependency-free module beside `routes.ts`: `adminGate` decides a path from the table's `auth` column (the most specific route wins), `currentAdminSession` asks the host who is signed in and whether the membership list holds them as an admin, remembering the verdict for a short time, and `ssoRedirect` makes the hand-off to the content system. A project with no `Admin` row gets no file and the rest of the output is unchanged. `--check` covers the new file. The row is refused when the login page is not public, the hand-off is not an `admin` endpoint, or a path or role is wrong. `docs/site-routes.md` lists the fields.

## [3.4.2] - 2026-10-05

A patch on 3.4.1. It closes four verb gaps (`site_projection.check_live` takes `template=<file>` and prints just the report, `hecks package.digest` prints a package's digest and shape, `operation.bootstrap_admin` says what to add when the domain has no membership chapter, and `deploy recipe.project` runs from an installed gem), extends the Memory adapter's O(change) saves to one large nested value object, and turns the deploy scripts into Deploy-chapter commands, starting with `hecks deploy smoke_run.run` (#1043, [ADR 0090](docs/decisions/0090-deploy-scripts-become-commands-on-the-deploy-chapter.md)). Two things to know before bumping. First, a journalled value object in the Memory adapter is now frozen, so editing it in place raises `FrozenError`; that edit used to succeed and silently corrupt the journal, so, as with 3.4.1, the change turns a silent corruption into a loud error and no working code depends on it. Second, the `smoke_run.run` entry carries no label of its own ("`hecks deploy smoke_run.run` runs a project's generated post-deploy smoke as a command, and `make deploy` calls it"), and it is additive until a project regenerates its recipe: the command is new and the existing script is unchanged. A regenerated Makefile does behave differently, though: `make deploy` then needs a Hecks database (`HECKS_DATABASE`) and a failed smoke exits 1 instead of 20 to 23. Nothing changes for a deployed project that does not regenerate, and deploys pin exactly, so regeneration is the project's own choice; it is a patch on that reading, and a project that regenerates should read that entry first. Nothing in the DSL or runtime API is removed.

**Changed: `hecks site site_projection.check_live` takes `template=<file>` and prints just the report.** A project whose `Edge` row leaves `template:` out was refused by `check_live` although `project_site` accepted `template=<file>` for it, so a client had to add a placeholder row. `check_live` now takes the same `template=<file>` (it reads no template, so the file need not exist). It also prints the report alone, the differences or the line saying the distribution matches, and exits 1 when any differ, instead of the whole JSON record with the report as a reason on standard error. A world's `launcher` setting names such commands under the new `report:` key.

**Added: `hecks package.digest <package> [root=<dir>]` prints a package's content digest and shape label.** The digest a consumer records in its `bluebook.lock` was reachable only from Ruby (`Lock.digest_of`, in a `ruby -rhecks -e` one-liner). The new query prints it, `digest: <sha256>`, then one `shape: <label>` line per bluebook, over the package's `bluebook/*.bluebook` files alone, from a registry (`<root>/<package>/bluebook`) or a project that vendors it (`<root>/vendor/embryonaut_bluebooks/<package>/bluebook`). It is also spelled `registry.digest`.

**Changed: `hecks operation.bootstrap_admin` says what to add when the domain has no membership chapter.** The refusal named only the missing capability. It now shows the line to add, `provides "membership", admit: "Person.Admit", grant: "Person.GrantAccess", people: "Person.All"`, and says what each verb names; `docs/running-a-rules-service.md` documents the requirement.

**Fixed: `hecks deploy recipe.project` runs from an installed gem.** It refused with "needs a hecks checkout" outside a checkout of this repository, and it read a relative `<domain>` from the gem's own directory rather than from where the command ran. It now reads the project it is given, a path absolute or relative to the current directory, and writes the recipe under `deploy/<stack>/` of that directory (or `out=`). In a checkout the generated recipe is unchanged; outside one the Makefiles name the directory the command ran in as their root. `makefile_check.lint` and `oidc_manifest.project_oidc` still need a checkout.

**`hecks deploy smoke_run.run` runs a project's generated post-deploy smoke as a command, and `make deploy` calls it.** Give it the project (`smoke_run.run <project>`) and it finds the `smoke-after-deploy.sh` the `AwsBox` projection wrote, beside the Makefile or the only one beneath the project (`script=<path>` overrides; `taskdef=`, `skip=true`, `async=true` and `dry_run=true` map to the script's variables). It records a `SmokeRun` in the Deploy chapter as `passed` with what the script printed, or `flagged` with the script's status (20 the roll did not settle, 21 `gh` unavailable, 22 the smoke failed, 23 result unknown), exiting 1 when flagged. The generated Makefile (and `hosting.mk`'s `smoke-after-deploy` target) now run `$(HECKS) deploy smoke_run.run project="$(CURDIR)" --wait` instead of the script, so each deploy leaves a durable `SmokeRun` in the Hecks database (`HECKS_DATABASE`, default `postgres://hecks@localhost/hecks`; the deploying machine needs it, `createdb hecks` once). A failed smoke is exit 1 rather than 20 to 23. When the database cannot be opened the target prints that error and the setup step, still runs the script so the smoke's result is printed, and exits non-zero (the smoke's own status, or 24 when it passed); regenerate a project's recipe to pick this up. The script itself is unchanged and `deploy-service.sh` still calls it directly. [ADR 0090](docs/decisions/0090-deploy-scripts-become-commands-on-the-deploy-chapter.md) lays out the rest of the deploy scripts.

**A clean `model_check` run now records how many domains it examined.** `ModelCheckRun` keeps a `checked` count beside the `report`, counted by the adapter from the report's domain headers, so an agent behind the MCP door reads a number instead of counting lines of a long report (three runs of the same check once gave 80, 58 and 69).

### Fixed

**A Memory-backed aggregate with one large nested value object no longer pays for its whole size on every save.** The 3.4.1 fix shared the elements of a top-level `list_of`; a single value-object attribute that holds a list (directly, or through a nested value object) was still copied whole into the journal and hydrated whole into the record on every save, so a `Step` that changed one counter cost O(size of the value object). A hydrated value object is frozen, so Memory now copies it once, freezes the copy, and shares it between every journal entry and record that holds it; a new version of the value object reuses the copies of the list elements it still holds (`Memory::SharedElements`, plus `Runtime::Value#raw_fields`, a reader for the stored fields). A journalled value object now refuses an in-place change (`FrozenError`), the same tightening 3.4.1 made for list elements; an entry still has exactly the shape `StateCodec.copy` gives a durable adapter, and a returned instance still shares nothing mutable with the journal. A value object that is not frozen, or an attribute with no list in it, takes the whole-copy path as before. One game whose `Log` value object holds N cells (Memory), one `Step` that touches only a counter:

| Cells in the value object | Before: time per step, allocations | After |
|---|---|---|
| 20 | 4.3 ms, 1,338 | 0.15 ms, 513 |
| 200 | 20.7 ms, 8,718 | 0.25 ms, 513 |
| 2,000 | 200 ms, 82,518 | 0.43 ms, 513 |
| 20,000 | 1,971 ms, 820,520 | 0.15 ms, 513 |

A value object that gains a cell on every save (save only):

| Cells | Before: time, allocations | After |
|---|---|---|
| 20 | 0.21 ms, 1,126 | 0.17 ms, 311 |
| 200 | 3.2 ms, 8,506 | 0.28 ms, 311 |
| 2,000 | 215 ms, 82,306 | 1.1 to 2.5 ms, 311 |

Allocations per save no longer follow the size. A value object whose list is rebuilt still costs one cheap pointer lookup per existing element in time (about 1 ms per 2,000 cells), not a copy of each.

## [3.4.1] - 2026-10-05

A patch on 3.4.0 with one user-visible fix: a Memory-backed aggregate with a growing `list_of` no longer pays a quadratic cost over a run (present since 1.4.0). It carries one tightening to know before bumping: a list element inside a Memory journal entry is now frozen, so editing a journalled element in place raises `FrozenError`. That edit used to succeed and silently corrupt the journal, so the change turns a silent corruption into a loud error and no working code depends on it; it is a patch for that reason, not a `Behavior change`. Nothing in the DSL or runtime API is removed.

**Fixed: a Memory-backed aggregate with a growing `list_of` no longer slows down with every save.** Since 1.4.0 the Memory adapter journals a codec copy of the state, and builds each record from another copy plus a full hydration, so a save cost O(everything the list holds) in time, and the journal kept a full copy per save: quadratic time and memory over a run. A hydrated element of a composite `list_of` is frozen, so Memory now copies and hydrates each element once, freezes the copy, and shares it between every journal entry and record that holds it (a weak, identity-keyed table; `Memory::SharedElements`). A save costs one pointer lookup per existing element plus the full copy of the new ones. A returned instance still shares nothing mutable with the journal, a journalled element now refuses an in-place change (`FrozenError`), and an entry has exactly the shape `StateCodec.copy` gives a durable adapter. One aggregate, 32 pieces per snapshot, one snapshot per step (Memory, `list_of` of value objects):

| Steps | Before: time, last-10 per step, peak RSS | After |
|---|---|---|
| 50 | 1.9 s, 73 ms, 172 MB | 0.07 s, 1.1 ms, 88 MB |
| 100 | 7.1 s, 127 ms, 244 MB | 0.21 s, 1.5 ms, 95 MB |
| 200 | 29.5 s, 264 ms, 534 MB | 0.3 s, 1.2 to 1.8 ms, 98 to 104 MB |

A list element that is not frozen, a list of scalars, and every other field still take the whole-copy path. `Runtime::Instance.new` takes an optional `hydrate_with:` callable, used by Memory to hydrate through the shared elements.

## [3.4.0] - 2026-10-05

A minor that removes the five spellings 3.3.0 warned about (`uses_framework`, `uses_embryonaut_bluebook`, `Hecks::Facade`, `Hecks::Doors::Surface` and `install_facade:`), the removal that 3.3.0's warnings named. Using one now fails with a message naming its replacement, so a project must migrate before it moves its pin past 3.3.x: the table is in [`docs/migrating-2-to-3.md`](docs/migrating-2-to-3.md), and the `Removed (3.4.0)` entry below says what each one becomes. Deploys pin exactly (`docs/1.0-readiness.md`, "What a release number promises"), so a running system stays on 3.3.x until it is migrated.

**Removed (3.4.0): the five spellings 3.3.0 warned about.** The removal was promised in 3.3.0 and in #1012; each now fails
instead of warning. Replace them before upgrading a pin past 3.3.x (the table is in `docs/migrating-2-to-3.md`):

| Removed | Use instead |
|---|---|
| `uses_framework "X"` | `attaches "X"` |
| `uses_embryonaut_bluebook "x"` | `attaches "x", from: :vendor` |
| `Hecks::Facade` | `Hecks::Doors` |
| `Hecks::Doors::Surface` | `Hecks::Doors::RubyDoor` |
| `install_facade:` on `boot`, `boot_files`, `boot_described` | `install_doors:` |

A hecksagon that still writes either word is refused by name, by Ruby and by the Rust parser alike: ``uses_framework was
removed in 3.4.0; use `attaches "Name"` ``, rather than being read as a stray default bind. The two words are gone from the
Hecksagon language table, so `hecks language_run.project_reference` no longer documents them. The other three raise `NameError`
and `ArgumentError`.

**Fix: a drafted bluebook no longer fails to boot when an action was accepted more than once.** An expert who refines an answer over several exchanges gets the same action accepted again, and the draft wrote one `command` block each, which the runtime refuses ("Declare creates a Command that already exists"). The draft now writes each action once: the first acceptance's event stays, what the acceptances take and who does it are joined, and it creates if any acceptance said so. A thing accepted twice becomes one aggregate.

## [3.3.0] - 2026-10-05

A minor with one `Behavior change` entry: `hecks package.vendor` and `package.revendor` now exit 1 when a package is refused, which can break a script that ignored the status; read it before bumping a running system. Nothing in the DSL or runtime API is removed. The deprecated `Hecks::Facade` names, `install_facade:`, `uses_framework`, `uses_embryonaut_bluebook` and the `attaches` / `install_doors:` spellings still work and now warn that they are removed in 3.4.0 (previously 3.3.0 or 3.2.0).

**Changed: the release workflow no longer needs a laptop when the RubyGems API key fails.** `release.yml` retries the
`RUBYGEMS_API_KEY` push with backoff, then falls back inside the same job to RubyGems trusted publishing over OIDC. A version
already on rubygems.org counts as pushed, so a re-run finishes a half-done release, and when both paths fail the error names
the key scope or the trusted publisher entry to configure. Later steps wait until the registry lists the version.

**New: `hecks site site_projection.check_live` compares a project's generated CloudFront behaviours with a live distribution's.**
Given a saved `aws cloudfront get-distribution-config` answer (`live=<file>`), or a distribution id to fetch it with that one
read-only call (`distribution=<id>`), it matches each behaviour by path pattern and reports every difference in origin,
methods, viewer protocol, compression, the three policy ids and order, and the behaviours only one side has. `expect_new` names
the behaviours a pending deploy adds, and `refs` says what each `!Ref` policy intrinsic stands for live. A difference is exit
status 1 with the report on standard error; a match is exit 0. Nothing on either side is changed.

**New: `hecks operation.bootstrap_admin` gives a domain its first administrator.** A domain whose chapter `provides "membership"`
has nobody who may grant access until someone is granted it, and each project wrote a script for that one step. `hecks
operation.bootstrap_admin <domain> email=<email> [name=<name>] [role=<role>]` boots the domain, reads the admit, grant and
people verbs the chapter declares, admits the person if they are not already, and grants them the role the grant command is gated
to (or `role`). The dispatches run as a caller that names that role and binds no `actor_id`, the unidentified bootstrap caller
Governance checks by the role it states (ADR 0025). Once anyone holds `Admin` (or the gating role) or `Owner` it is refused with
exit status 1, naming the holder, and nothing changes. The domain's persistence must be the one the service uses, so run it with
that `DATABASE_URL`; a Memory-bound domain forgets the grant when the command ends.

**New: `hecks package.check` and `hecks package.release` run a bluebook registry's version rules and tag its releases.** In a
registry repository (packages at `<name>/bluebook.yml`, tagged `<name>-vX.Y.Z`), `package.check` fails, with exit status 1 and one
`FAIL` line per package, when a package's `*.bluebook` files changed since its latest release without a newer version and a
`CHANGELOG.md` entry, when a `bluebook.yml` has no `X.Y.Z` version or the wrong name, or when a release tag sits on a commit whose
`bluebook.yml` says another version. `package.release <package>` makes the annotated tag locally, refusing for an existing tag, a
version that is not newer, a missing changelog entry, uncommitted changes, or files identical to the last release; it never
pushes and ends its report in the push command. Both are answered by a new `Registry` aggregate in the Custodian chapter, through
the `Git` adapter and `Hecks::EmbryonautBluebook::Registry`. Run against a copy of a real registry, the verbs made the same
decisions and wrote the same tag messages as its `bin/check_versions` and `bin/release` scripts.

**New: `hecks package.verify` checks the vendored packages against `bluebook.lock` and prints the project's bluebook manifest.** A
project that vendors registry packages no longer needs its own script to prove the files match their locks before an image is
built. `hecks package.verify [root=<project>]` reads every `vendor/embryonaut_bluebooks/<package>/`, compares the digest of its
`*.bluebook` files with the lock (through `Lock.digest_of`, the one digest implementation), checks that the lock carries every
field and that its tag is `<package>-v<version>`, and answers the manifest as JSON: per package `version`, `tag`, `commit`,
`digest` and `shape`, plus the project's `built_from` commit and whether its tree is dirty. A disagreement is exit status 1 with
one `FAIL` line per package. The text is byte-for-byte what a Python manifest script printed for the same tree.

**Operator-only code leaves the gem, and client and organisation names are scrubbed from the tree.** `qa/lambda_handler.rb` (the Lambda entry for the GitHub CI webhook) and the `deploy/quality-control-webhook/` SAM stack moved to the operator's own platform repository; `GithubCiWebhook` stays here. The `deployed_to("AwsLambda")` block that generated that stack is gone from `qa/bluebook/quality_control.world`, and `aws-sdk-secretsmanager`, which only the handler used, is out of the Gemfile. Generator comments, examples, specs, fixtures and the deploy goldens now use neutral owners and names (`owner "Core"`), `SECURITY.md` names GitHub's private vulnerability reporting as the reporting channel, and the comment-style guides spell the launcher verbs as they are (`hecks style_run.check_comments`, `hecks build.project_rust`).

**`AwsBox` generates the per-service hosting scripts a project keeps by hand.** `hosting_scripts true` (with `smoke_workflow`, and `hosting_stack` when the world names a `task_definition`) adds `deploy-service.sh`, `smoke-after-deploy.sh`, `expected-era` and a `hosting.mk`, the way `AwsFargate` does. `deploy-service.sh` pushes a local image under a fresh tag that ECR must not already hold, sets only that container's image-tag parameter on the hosting stack and checks that nothing else changed, refuses to roll a task definition that does not carry the pushed image, and rolls it with `deploy-box.sh`; `EXISTING_TAG` redeploys a tag already in ECR. `smoke-after-deploy.sh` waits for the box to settle (stack status, every container and the proxy up and stayed up, and each container running the image the latest task definition names, on two agreeing checks) before it dispatches the smoke workflow and follows the run, with exit codes 20 to 23. `make deploy` then ends with the smoke. A hosting word without `hosting_scripts true`, a missing `smoke_workflow`, and a `task_definition` without a `hosting_stack` are refused. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`hecks build.build_host` builds the Rust host for a domain and stages it for an image.** It builds the domain's
`.wasm` and `.ir.json` as `build.build_wasm` does, compiles `rust/host` in release from the installed gem's workspace
(`.hecks/rust/<version>/` in a project, so the host is the release the Gemfile resolves and nothing is cloned), and
copies `<domain>-host`, `<domain>.wasm` and `<domain>.ir.json` into `stage_dir=` (default `.hecks/host/<target>/`), the
files a container image `COPY`s. `target=<triple>` cross-compiles (default: the machine's own); a target that is not
installed, a wasm target, a missing `rustup` and a malformed triple are refused with the command that fixes them, and
`--wait` makes a refusal exit 1. Cargo's output stays in the workspace's `target/`, so a second build is incremental.
The `Build` aggregate gains the `BuildHost` command, the `TargetTriple` and `StagePath` values and the
`RustToolchain` port's `Host` ask; the Rust meta, vocabulary and frozen Bluebook IR are regenerated.

**CI runs the gate's checks instead of copying them.** `lib/hecks/gate/stages.yml` gains a `ci` stage (every check `ci-checks.yml` ran: model check, engine agreement, doc coverage, rubocop, both comment checks, codegen, vocabulary and kernel drift, rust coverage, the deploy-recipe lint and the three fuzz sweeps) and a `post_commit` stage. A check two stages share is written once, under a YAML anchor, so `pre_push` and `ci` cannot drift. Each `ci-checks.yml` step is now `hecks gate_run.gate stage=ci only=<ids> --wait`: jobs, runners, logs and attestation conditions are unchanged, and only the commands moved. `.githooks/post-commit` is a shim over the `post_commit` stage, as `pre-push` is over `pre_push`. `spec/gate_ci_stage_spec.rb` fails when a workflow step carries a command of its own or a `ci` check is run by no step. The eight required-check wrappers in `ci.yml` share one `require-result` action, and the attestation write is the `write-attestation` action. A green `gate` run prints which checks passed, not their output; a red one prints it all.

**The per-day PR cap is a `DailyQuota` aggregate.** `hecks quality_control patch.open` no longer counts `Patch` and `Improvement` rows since local midnight: the QualityControl ledger has a `DailyQuota`, one record per UTC day, whose `Take` refuses once `PR_CAP_PER_DAY` is spent and whose day the runtime fills (`needs :today`). The script dry-runs `Take` before it opens a PR and takes the slot once the PR is recorded. The `OpenedSince` queries and the adapter's `assert_under_daily_cap!` are gone, and so is the `branch_prefix` dial, which repeated the prefix `Patch.Open` and `Improvement.Open` already declare. The day is now the UTC day.

**Behavior change: `hecks package.vendor` and `package.revendor` exit 1 when the package is refused, and say why.** Both
commands now wait for their reactions as `--wait` does, so a downgrade without `ALLOW_DOWNGRADE=1`, a shape change on
a patch bump, a package the source does not carry and a missing source repository end with exit status 1 and the
reason on standard error. Before, the launcher printed the `Package` record still in `requested` and exited 0, so a
script or CI could not tell the pin had not happened. A bad name was already refused with exit 1. The record is still
kept (`package.pinning`, `package.unpinned`). The mechanism is general: a `settled` list in the `launcher` world setting
names commands that always wait, and a `--wait` failure now appends the record's own `refusal` to its reason. A script
that read the record from the old exit-0 output should read the exit status.

**A query can declare `needs`, and there is a `today` fact (ADR 0081).** A query writes `needs :now`
(or `needs :today`, the day the clock falls in, whole days since the epoch in UTC) and declares the
attribute it fills; the runtime answers it before the query's filter reads its arguments, unless the
caller passed a value of its own. Ruby, the Rust parser, the Rust host and the kernel all do it, and
`today` is available to commands too. The Query IR carries `needs` only on a query that declares
one, so no existing IR changes; a query's log echoes the arguments the caller offered. `lease_clock`'s
`Expired` query now needs `now`. `Hecks::RustBuild::KernelInput` also sends a standalone binary the
`needs` and `query_needs` tables, as the host does.

**`hecks-codegen` prepares its own IR and writes its own sidecars.** It now marks the fields an `append` binds to an optional argument, and writes each chapter's `ir.json` and `metadata.rs`, so `hecks project_rust` and the Ruby-free `hecks-build` both drop their copies: the Ruby `AppendOptionals` and `RustLiteral`, and `hecks-build`'s `optional_pass.rs` and `sidecars.rs`. One mutable JSON type in codegen reads numbers as written and writes what `JSON.pretty_generate` writes. `hecks regenerate_corpus --check` stays clean, so every committed `ir.json` is reproduced byte for byte.

**CI cuts the release.** `.github/workflows/release.yml` runs when a commit on `main` changes `lib/hecks/version.rb`: it checks that the gem, `@hecks/client`, `rust/host/HECKS_RELEASE` and the CHANGELOG heading name one version, tags the commit, pushes the gem with the `RUBYGEMS_API_KEY` secret, starts the npm publish and creates the GitHub Release from the CHANGELOG section. Every step skips what already exists, so a re-run finishes a release that stopped halfway. `hecks publishing_run.publish --confirm` still works for a release by hand.

**`hecks interview` drafts what a thing has and how it changes state.** The interview takes two more findings: a **field** a thing has, with the values it may take when the expert listed a closed set, and a **transition**, the state an action leaves a thing in and the state it had to be in before. An action also records the fields it takes and who does it. The draft writes a field as an attribute (optional unless the creating action takes it), a closed set as `one_of`, a command's inputs as its attributes with `sets`, and the transitions as a lifecycle that starts where the creating action leaves the thing. Who may do an action is written as a comment, not a `role`, because a role is checked only once the domain attaches Governance. The interviewer is also told when a thing is not yet said to have anything, or to change state.

**The launcher forms of `docs/tools.md` are generated.** What each retired `bin/` script became is
declared once, as `RetiredScript` rows in the Vocabulary chapter, and `hecks
regeneration_run.project_tools_doc` writes the document's tables from them, rendering each form from
the command's own arguments (the same projection the launcher parses against): the first argument is
the bare word, `name=` takes the rest, a switch is `--name`. A form can no longer keep an argument its
command dropped. Without `--confirm` the verb only compares, and CI runs it. `Hecks::ThreeZero::FORMS`
and `lib/hecks/three_zero/forms.yml` are gone; `Hecks::Tools::ToolsDoc.forms` answers the same table,
rendered. The ADR command-table spec reads the rows instead of its own copy of them.

## [3.2.1] - 2026-10-05

A patch on 3.2.0, which was tagged before the entries below landed. The deprecated `attaches` / `install_doors:` spellings warn that they are removed in 3.3.0 (previously 3.2.0); the 3.2.0 gem's warnings still say 3.2.0. Behavior is unchanged.

**`AwsBox` refuses an origin secret that does not match the task definition's.** With a `task_definition`, only Caddy reads the named origin secret while the containers keep the task definition's copy, so a copy that differs made every request through the CDN fail and nothing said why. A world can now name the variables that hold it (`origin_env ["CLOUDFRONT_ORIGIN_SECRET"]`); `render-compose.sh` compares them with the named secret and refuses to render on any difference, or when no container sets a named variable, without printing a value. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**The era check takes its timeout from the caller.** `CheckEra.run`, the old argv entry nothing called, is removed, and `timeout:` is now required in the `ExpectedEra` helpers, so the command's declared default is the only one. ([#1013](https://github.com/heckslabs/hecks/pull/1013))

**`hecks-codegen` is the only Rust generator.** `hecks project_rust` builds the IR from the live registry and runs `hecks-codegen` on it; the Ruby generator in `rust/project`, its `HECKS_PARSER`/`HECKS_CODEGEN` pipeline opt-in and the `HECKS_CODEGEN=ruby` rollback are gone (ADR 0086). Generating Rust now builds `hecks-codegen`, so it needs Cargo; an installed gem builds it into the workspace copy's own target directory, never into the gem. The Ruby-versus-Rust parity specs became `spec/codegen_planted_gaps_spec.rb`, a frozen manifest for the construct families no corpus domain has; `hecks regenerate_corpus --check` still diffs every corpus domain against the committed tree.

**`AwsBox` deploys no longer show a visitor a 502.** A request that arrives while a container is being replaced now waits and is retried every 250 ms for up to 15 seconds (`lb_try_duration` on each upstream), so a roll costs a slow page instead of an error; no second copy of the container, and no extra cost. On a live client box, recreating the website container answered 3 of 108 requests with a 502 before and none after. The roll also restarts the proxy when its Caddyfile changed: the Caddyfile is a bind-mounted file and the admin API is off, so without that a regenerated Caddyfile never took effect. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**Fix: `run_spec_example` runs more than once in a process.** A door that stays booted ran the
first spec example and returned empty reports, marked completed, for every later one: RSpec keeps
the first run's output stream, so the next run wrote into that. The runner now resets RSpec before
each run, and a run that prints nothing is refused, since a real run always prints its summary.

**The `hecks mcp` door says how to call it (ADR 0089).** A door that serves one domain makes `domain:`
optional and fills it in. On a commands door, `dispatch` lists each allowed command in its description
with the role it declares, what it does and its argument names (`*` marks a required one), and says to
pass that role as `role`. `dispatch` now answers the record as it stands once its reactions have run,
as `--wait` does, so a run record a reaction completes reads as `completed`, not `requested`; this
holds for every door. Together they let an agent call the door with no usage manual. The guide is
kept in a cache (`McpGuideCache`) keyed by the domain's files, the hecks code and the allowed
commands, so `tools/list` stays as fast as before. A sandboxed door keeps the cache under the temp
directory, so its first start after a change to the hecks code is cold (about half a minute): start
it once before an agent needs it.

**The Rust host fills a declared default on an entity's command, nested entities included.** ([#1015](https://github.com/heckslabs/hecks/pull/1015))

The Site chapter, after its first adoption by a client project. A route table written for 3.1.x generates the same
`routes.ts` and the same template regions, apart from the one change under **Changed** (the `matchesPath` helper in the
module), unless it uses what is added below; the one new refusal is noted there too.

### Added

- **`hecks site site_projection.project_site` runs from a client project with the installed gem.** It no longer needs a hecks
  checkout, and the project, the output and the template are independent: `out=<dir>` is any directory for `routes.ts`, and
  the new `template=<file>` is any file to rewrite in place (the `Edge` row may then leave out `template:`). Both are read from
  where the command runs; with `out=` alone the template is still copied under it. A flag outside the rules is refused: an `out=`
  that is a file, a `template=` that does not exist or is named for a project with no Edge rows.
- **`extension=mts`** writes `routes.mts` (the same text) so Node can import the module from a `"type": "commonjs"` package.
  `ts` stays the default.
- **`alb: false` on the `Edge` row** for a project with no load balancer: no `listener_rules` region is needed or written, and
  `EdgeRule` rows and `alb_rule` are refused. A route on the cms or the domain still needs an `EdgeOrigin` mapping its origin.
- **Navigation to anything that answers GET, to a fragment, and under a heading.** A row of any kind may sit in a menu; a
  `NavLink` row (`path`, optional `fragment`, `label`, and the slot fields) adds a second link to a route, such as
  `/about#hours`; `mobile_heading` on a row opens a section of the mobile menu. Entries carry `fragment` and `heading` only when set.
- **An off page keeps its navigation slots.** Its entries carry `switch` and `on: false`, and the site drops them while
  `pageIsOn(switch)` is false. Entries of pages that are on are as before.
- **`edge_methods` on a route**: the verbs the edge lets through, apart from the verbs the route answers (`methods`), so an admin
  page can answer `GET` and still ride the `/admin*` behaviour.
- **`seo_title` on a route**, written to `ROUTES` as `seoTitle` for the rows that set it.
- **A public page beneath an admin prefix** is expressible: name its `cache` (and `indexable: false`) and it rides the prefix.

### Changed

- **`matchesPath` in the generated `routes.ts` reads `*` as a CDN does**: any run of characters, `/` included, wherever it stands.
  A prefix row such as `/admin*` used to match nothing and now matches `/admin`, `/admin-inbox` and `/admin/members`. This changes
  the text of the helper in every project's `routes.ts`, so `--check` reports it until the file is regenerated; only a pattern with
  a `*` inside a segment, which matched literally before, changes meaning.
- **A public row beneath a route that is admin or signed must name its `cache`.** Such a row used to take the `page` class from
  its auth; a table that has one with no `cache:` is now refused, naming the prefix, and is fixed by writing the class it meant.
- **An off row may now sit in a navigation**; it was refused before, so no existing table is affected.

## [3.2.0] - 2026-10-05

A minor: additive, nothing breaking, and no behavior change for a running system unless it opts in. A site that acts for a signed-in person can now name them: `@hecks/client` sends `actorId`, and the host's `/accounts/me` and `/members` carry each person's `identity_id`, so Governance's role assignments decide.

**`hecks deploy cost_check.check` says whether hosting is within a budget.** `budget=75 since=2026-10-05` reads the daily bill from that day up to yesterday with `aws ce`, scales the mean to a month, and records the check as `within_budget` with a one-line report naming the biggest services, or as `flagged` with the figures (exit 1 under `--wait`). It is a `CostCheck` aggregate in the Deploy chapter that asks a new `CostExplorer` port, bound to an adapter in the Hecks domain. Hecks has no scheduler yet, so something outside has to call it. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))
**`AwsBox` rolls the box faster and writes executable scripts.** `deploy-box.sh` no longer sleeps a fixed 20 seconds after starting the containers: it waits until every container has been up at least 5 seconds, and still catches one that restarts or exits right after starting. On a live client box that cut the roll from about 40 seconds to 16. The generated `.sh` files are also written with the executable bit, so a caller can run `./deploy-box.sh` directly. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`@hecks/client` can send `actorId`.** `ClientOptions.actorId` (a default for every command), `Command.actorId` and a fifth `dispatch(verb, args, to, role, actorId)` argument send the body's `actor_id`, the Governance identity id of an identified caller. Leave `role` unset and Governance's role assignments decide; the host honors `actor_id` only on its internal protocol. The key is omitted when unset, so existing calls are unchanged.

**The host's account routes carry each person's identity id.** `GET /accounts/me` now answers
`{"email", "identity_id"}` and each row of `GET /members` gains a trailing `identity_id`, so a site or
CMS acting for a person can pass it as `actor_id` and have Governance check the right role assignment.
It is read from the same membership head as `GET /api/me`. A member who has never signed in has no
identity yet, so their `identity_id` is `null`. Existing fields and their order are unchanged.

## [3.1.3] - 2026-10-05

A patch: nothing breaking, and no behavior change for a running system. It puts the pizzas example in
the gem, so `hecks console` works after a plain `gem install hecks`.

**The gem ships the pizzas example.** `hecks console` opens `examples/pizzas` when given no domain, and
the gem shipped no examples, so a plain install failed with a `LoadError`. The gem now carries
`examples/pizzas` (eight small files, without its glossary), and the README quickstart and the
getting-started guide start from `gem install hecks`. `hecks init` and `hecks interview` already worked
from the gem.

**`hecks` help hides the internal commands.** The 3.1.2 entry above describes this change, but it landed
after 3.1.2 was tagged, so it first ships here: the default help leaves out the bookkeeping each
journaled run dispatches for itself, ends with a line saying how many were left out, and `hecks --all`
lists them.

**An agent can run under a profile.** `Agent#ask` takes an optional `AgentProfile`: a run under the macOS
sandbox with credential reads refused, writes limited to the named directories, the network shut unless
opened, only the named environment variables passed on, and a timeout that kills the agent's whole
process group. A profile can confine by the sandbox or by `claude`'s own permission rules, which keeps a
`claude` login working. `hecks quality_control mine_combinations --confine` runs the default agent this
way. Asks without a profile behave as before. A profile also sets the network (`none`, `https` or `any`),
a timeout and a spending cap; under the permission rules the agent runs with no MCP servers, and
`--confine` lets the miner write only its candidates directory, for at most twenty minutes and two
dollars. The `https` network setting is written but not exercised by the specs.

## [3.1.2] - 2026-10-04

A patch: nothing breaking. It fixes a second 3.1.0 regression: a lifecycle `transition` with no `from:` was read as "only from the empty state", so a command that creates its aggregate, whose lifecycle starts at a default, was refused. 3.1.1 fixed Boolean attributes; this release fixes that one. Skip 3.1.0 and 3.1.1 if a domain builds Rust from a bluebook.

**`AwsBox` can overwrite named secrets in production, and mount a smoke listener on a rehearsal.** `writable_secrets ["name"]` lets a production box (never a rehearsal) overwrite those secrets, for a project whose admin page stores a pasted key. `SMOKE_LISTENER=1 make deploy` mounts a loopback HTTPS listener under `caddy-extra` on a rehearsal box that adds the origin secret, so a browser-driven smoke run can reach it without the CDN. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`hecks` help no longer lists the internal commands.** The bookkeeping each journaled run dispatches
for itself (`accept`, `complete`, `fault`, `examine`, `perform` and the read-backs of every `*_run`
aggregate, about 128 names) nobody types, and they filled two blocks of the default output. The help
leaves them out and ends with a line saying how many were left out; `hecks --all` lists them as before,
and `--help` on any of them still works.

**An `edge` tag follows main, so a project need not wait for a release.** A workflow moves the `edge` tag
to every commit that lands on main (forward only; nothing publishes from it, since the publish workflows
listen for `v*`). A Gemfile can take `git: "https://github.com/heckslabs/hecks.git", tag: "edge"`, and a
deploy can say `hecks_release "edge"`: the generated `hosting.mk` then fetches the tag afresh on every
build, skips the exact-release-tag check for it alone, and prints the commit it built. A build from `edge`
is not reproducible from the name, so pin a release when that matters. Regenerate a project's
`hosting.mk` (`hecks deploy recipe.project`) to get the new recipe.

**`hecks-codegen` admits every state for a lifecycle transition with no `from:`, as the Ruby generator did.** A `transition "Open" => "open"` with no `from:` is unconstrained, but the generated Rust checked the command against the empty state, so a command that creates its aggregate (which starts at the lifecycle default) was refused with "moves it only from \"\"". The generator now emits no transition check for an unconstrained row, which is what 3.0.x emitted. A domain that declares such a transition and built on 3.1.0 or 3.1.1 should rebuild its wasm on the fixed release.

**Behavior change: a registrant gets a receipt email once their payment settles (added to this entry after the release).** The Rust host emails a registrant whose payment just succeeded (the mock checkout completing, or the Stripe webhook), naming the event and the amount. Only the delivery that settles the payment sends it, so a redelivered webhook stays quiet, and nothing is sent where no mailer is configured. The host also asks the site's `/api/session-details` for the session's date, time and venue, and asks the site for the finished email (editable in the CMS), falling back to its built-in wording; if the site does not answer, the email goes out without those lines.

## [3.1.1] - 2026-10-04

A patch: nothing breaking and no behavior change for a running system unless it opts in. It fixes a 3.1.0 regression: a domain with `TrueClass` or `FalseClass` attributes no longer compiled to Rust (see the `hecks build.project_rust` entry below). Skip 3.1.0 if your domain declares Boolean attributes in a value object.

**`AwsBox` fixes from its first real deploy.** The generated `deploy-box.sh` raced the box's first boot, because Docker and the Compose plugin are installed by user data, and failed on a fresh box; it now waits for first boot to finish. `make stacks REHEARSAL=true` makes a throwaway pair (the Makefile could not pass `Rehearsal`, and both templates default to production). The Caddyfile and the guide now say a rehearsal restarts the proxy to pick up a `caddy-extra` file, since its admin API is off. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`AwsBox` can render its Compose file from an ECS task definition.** `task_definition "<family>"` makes `render-compose.sh` read each container's image, environment and secrets from that task at deploy time, so a project running on Fargate moves its box by pointing it at the task it already has; the world lists only names and ports, and no ECR repositories are made. `deploy-box.sh` and `make deploy TASKDEF=family:revision` take a revision. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`AwsBox` generates three more parts of the stack it was modeled on.** The RDS stack takes an optional `BastionSecurityGroupId`, so the migration scripts' bastion can reach the new database. The Caddyfile imports `/etc/caddy/extra/*` and the proxy mounts `caddy-extra`, so a rehearsal can add a loopback listener and smoke-test without the CDN. `s3_access [{ bucket:, write: }]` gives the box role read on each bucket and write only on a production box. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`AwsBox` generates the tooling to move a project's data onto the new database.** A world that declares `migration({ schemas: [...] })` also gets `restore-to-rds.sh` (a per-schema `pg_dump | pg_restore` through a bastion, with the Hecks materialized-view refresh handled), `verify-copy.sh` (structure and exact row counts of both sides) and `MIGRATION.md` (the steps in order, with the rollback caveat). The bastion, hosts and secrets are arguments, so one set of scripts serves a rehearsal, the cutover and a copy back. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`hecks` prints its help about three times faster on a repeat run, and the help is grouped by
aggregate with the prefix left off.** Reading the domain's declarations was most of what the launcher
cost (about 0.9s of 1.2s); the help is now remembered under a digest of the domain's declaration
files, the gem's own library, the hecks and Ruby versions, the environment overlay and the command
line, so any edit to one of them is simply a new entry and nothing is ever stale. A repeat `hecks`
reads no declarations. `Hecks.describe` loads them on the first `registry` call instead of on return.
`HECKS_NO_USAGE_CACHE=1` turns the cache off and `HECKS_CACHE_DIR` moves it (default
`~/.cache/hecks`); an entry nobody reads for two weeks is swept on the next write. In the help, each
aggregate heading is the prefix of every call under it (`language_run:`), and the lines beneath drop
it (`project_model!`); a command the chapter gives a short name is listed by its real name with
`(also: mcp!)`.

**`hecks build.project_rust` maps `TrueClass` and `FalseClass` attributes to Rust `bool` again.** Since `hecks-codegen` became the only generator, a boolean attribute written in the Ruby-class spelling (`attribute :flag, TrueClass`) was emitted as a type named `TrueClass`, so the generated Rust failed to compile with `cannot find type TrueClass`. The scalar table in `hecks-codegen` now carries both spellings through the struct field, the JSON read and write, and the `Fielded` value, as `rust/project` did.

## [3.1.0] - 2026-10-03

A minor with two `Behavior change` entries, the first of which can break scripts: read them before bumping a running system. Nothing in the DSL or runtime API is removed. The deprecated `Hecks::Facade` names, `install_facade:`, `uses_framework` and `uses_embryonaut_bluebook` still work and warn; their removal, announced for 3.1.0, is now 3.2.0.

**A restricted `hecks mcp` door checks arguments by name (ADR 0089).** In reader and commands mode,
`dispatch` and `query` refuse an argument that names a host or a URL, a binary, an output, a port, a
store to switch to, or a switch from preview to change (`McpDoorScope::DENIED_ARGUMENTS`), a path
value that does not resolve inside the root with symlinks followed or that holds a colon
(`PATH_ARGUMENTS`), and a git ref that is not a plain name (`REF_ARGUMENTS`), including inside nested
values and every step of a batch. This closes the gap where an allowed command such as
`run_spec_example` could be handed a file outside the checkout. A spec lists every argument name of
every public command of the Hecks chapter and fails when one is unclassified. An unrestricted door is
unchanged.

**A `Site` chapter projects a site's route table into one `routes.ts`.** A project declares its routes
once, as `member` rows of a `value_object "Route"` in a chapter of its own, attaches `Site`, and runs
`hecks site site_projection.project_site <project>`. The projection (`:site_routes_ts`) writes a
dependency-free TypeScript module with the table as `as const` data and a few pure helpers: `pageIsOn`,
`isOffPath`, `notForSearch`, `previewUrl`, the middleware rules as data, the desktop, mobile, footer and
admin navigation, the sitemap paths, the robots prefixes, and a map from each CMS global to its page. A row
whose source is a `command:` or `query:` takes its path from the forms scheme (`/Chapter/Aggregate/Verb`)
and is checked against the chapters the project attaches. The closed sets a row's values come from (kind,
render, auth, cache class, origin, preview) are value objects of the Site chapter, so a row naming a cache
class that is not a member is refused with the members listed, and so are a path declared twice, an off page
in a navigation, and an off page with no switch. `--check` writes nothing and exits 1 naming each file
that differs. It is the first TypeScript Hecks generates. See `docs/site-routes.md`.

**`project_site` also projects the CDN.** A route table that declares an edge (`Edge`, `EdgePolicy`,
`EdgeOrigin` and `EdgeRule` rows beside its `Route` rows) has the same command rewrite two marked regions,
`BEGIN`/`END GENERATED site_cdn behaviors` and `listener_rules`, of the CloudFormation template the project
owns: the distribution's default and ordered cache behaviours, and the load balancer's listener rules with their
priorities and origin-secret condition. A route gets a behaviour only when CloudFront would otherwise apply a
different one; the order is the order the rows are declared in, and a pattern that a broader earlier one would
shadow is refused. Rows gain `compress`, `alb_rule` and `cdn`. The refusals name an unknown or unmapped origin,
a cache class with no policy, a duplicate priority and a rule that carries no route. `--check` covers the
regions, `out=<dir>` writes a copy of the template, and the catch-all row `/*` hides nothing from `NOT_FOR_SEARCH`.
`Fargate::Cdn.behavior_lines` is public and renders a `ResponseHeadersPolicyId`.

**One `attaches` word in the hecksagon.** `attaches "Governance"` loads a chapter the gem carries
(a framework member, or a chapter of the language, Tenancy, Deploy or QualityControl), found by
name in one table (`Hecks::Chapters.table`). `attaches "membership", from: :vendor` loads a package
vendored into the project at `vendor/embryonaut_bluebooks/<name>/bluebook`. `from: :vendor` is
required for a vendored package, so a typo cannot silently pick one over a gem chapter; an unknown
name refuses with a `WiringError` that lists the gem's chapters and says how to attach a vendored
package. A hecksagon now holds one list, `attachments`, each with its source (`:gem` or `:vendor`),
in place of `framework_members`, `vendored_bluebooks` and `attached_chapters`. The Rust parser and
build accept the same forms. `hecks model_check` now also flags `across "X"` on a hecksagon that
attaches a chapter the gem carries beyond the framework members, which it missed before.

Deprecated: `uses_framework` and `uses_embryonaut_bluebook` are the old spellings of `attaches`.
They behave as before, print a one-line warning, and are removed in 3.2.0, one release after the warning. Generated Rust files
now name their source as `attaches "X"`. See `docs/migrating-2-to-3.md`.

**Behavior change: the launcher says "command", not "verb".** `hecks` help lists `commands:` and `queries:`, each name
under its aggregate. A command is written with a trailing `!` (`hecks gate_run.gate! stage=pre_push`); the `!`
is optional on the command line. Queries are read with
`hecks query <name>`; `ask` stays as the same word. The projector's result keys are now `:commands`
and each spec's qualified name is `:command` (was `:verbs` / `:verb`); the journal's own `verb`
field is unchanged. The aggregate is part of the call: `hecks gate_run.gate`, not `hecks gate`. A bare name
is refused with the qualified names that end in it. A chapter's `names` table still gives
explicit short names (`mcp`, `console`). This breaks scripts, CI steps and Makefiles that call bare
names: qualify them (the bare-name refusal lists the candidates).

**Behavior change: `HECKS_ROLE_ENFORCEMENT=enforce` no longer refuses the host's own dispatches.** Signups, newsletter and registration flows, presentation saves, payment connection writes and the identity provisioning in sign-in dispatch with no caller of their own; under `shadow`/`enforce` they were read as the anonymous role and any command declaring a role refused them. A dispatch with no role from the host's own code is now unchecked in every mode, as it is under `off`. `shadow` also no longer lets through a caller that states a wrong role: only an unidentified or unassigned caller is let through and logged, so `shadow` is never looser than `off`.

**`hecks mcp` has a commands scope, and a restricted door stays booted.** With
`HECKS_DOOR_TOOLS=commands`, `HECKS_DOOR_DOMAINS` and `HECKS_DOOR_COMMANDS=check_comments,model_check`,
the door serves the reader tools and `dispatch` for those commands only. A command is admitted by the
verb it resolves to, so a short name shared by several aggregates (`complete`, `accept`) cannot reach
another aggregate's command, and every step of a batch is checked before any runs. `tools/list` shows
the allowed commands as an enum. The list admits commands, not argument values, so leave off any
command whose arguments name a binary, a URL or a path outside the checkout (ADR 0089). A restricted
door (reader or commands mode) now keeps each named domain booted until its directory changes, so a
call after the first no longer pays the boot; an unrestricted door still boots on every call.

**`AwsBox` pins its default images.** The Caddy proxy and the Cloudflare Tunnel default to a version tag plus the digest of the multi-architecture index, not a floating tag, so a rebuilt box pulls the same bytes. `proxy_image` sets the proxy's image; the tunnel hash already took `image`. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`AwsBox` can run a Cloudflare Tunnel.** `tunnel({ to: "<container>", token_secret: "<name>" })` adds a `cloudflared` service to the box's Compose project, forwarding to that container, reading its token from a Secrets Manager secret the box role may read, and waiting for a registered connection after the roll. `tunnel true` still only opens the outbound port. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`deployed_to("AwsBox")` is a deploy kind.** `hecks deploy project` now generates one RDS instance and one EC2 box that runs the domain's containers behind Caddy, as an alternative to the Fargate stack ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md)). The sizes are validated by a new `Deploy::BoxTarget.Declare` command; every other setting is checked before a template is written.

## [3.0.5] - 2026-10-03

A patch: nothing breaking and no behavior change for a running system unless it opts in.

**Opt-in (no change unless the variable is set).** The host's branded signup confirmation, below, behaves exactly as before until `NEWSLETTER_CONFIRMATION_TEMPLATE_URL` is set.

**Fix: `hecks console` no longer quits without a prompt.** IRB read the launcher's `ARGV` (the verb and `subject=<domain>`) as a script to run, failed, and the session ended after the banner with no error. The console now starts IRB with an empty command line and restores `ARGV` after (#959).

**A command attribute's declared default fills an omitted argument.** `attribute :runs, Count, default: 30` was carried into the IR and shown in help, but a caller who left `runs` out was refused with `AbsentArgument`. The interpreter now fills an absent argument that declares a default on every way in (the flat call, the strict `with:` envelope, a delegated entity command); an argument the caller passes is kept and an attribute with no default is still required. No command in the corpus declares a default yet, so nothing existing changes. The Rust host and kernel do not fill defaults yet, so a domain that starts using one needs the Rust side mirrored first (#958).

**The conformance corpus is language-neutral data; neither runtime is the oracle.** Every
`spec/corpus/rust_conformance/*.json` fixture, and the full `banking.json` and `chess.json` scripts,
now carries a frozen `expect` (instances, events, refusals with kind, queries, sagas, dry runs,
reactions) beside its `domain` and `steps`. `spec/conformance_corpus_spec.rb` holds Ruby to it and
`spec/rust_conformance_spec.rb` holds the compiled Rust kernel to it, where Rust used to be diffed
against a live Ruby replay. Ruby stays the reference implementation; the corpus is the authority.
`hecks test_suite_run.seed_semantics_corpus` now seeds both corpora (deliberately, once; review before committing).

`hecks seed_semantics_corpus` now seeds both corpora (deliberately, once; review before committing). A test-suite change; the runtime is unchanged (#951).

**`hecks help` groups verbs by aggregate and sets the bookkeeping verbs apart.** Output change only; no verb is renamed or removed (#947).

**Pre-push runs the comment style check CI runs.** A line past 100 characters used to pass the hook and fail CI; the check takes about 20 seconds (#952).

**Docs and guides.** The newcomer path now works from the docs alone (#953), the getting-started guide shows how to hook up SQLite (#955), and a new guide covers writing, running and deploying your own domain (#956).

**The host can send a branded signup confirmation (`NEWSLETTER_CONFIRMATION_TEMPLATE_URL`) (#957).** Opt-in: with the variable unset, the confirmation is the plain-text email as before. Set it to the URL of an HTML page and the confirmation email is that page with `{{CONFIRM_URL}}` (required) and `{{UNSUBSCRIBE_URL}}` (optional) replaced by the signed links, HTML-escaped. The host fetches it with a 5 second timeout and a 256 KiB cap. A missing variable, a failed, slow, non-2xx or oversize fetch, or a template with no `{{CONFIRM_URL}}` is logged and the plain-text confirmation goes out as before; signup is never failed or held beyond the timeout. Hecks ships no brand: the template lives with the site.

## [3.0.4] - 2026-10-02

**Fix (3.0.2 regression): code generation no longer refuses the data paths an era edge names.** The identifier check added in 3.0.2 walked every `name` in the IR, including `translations`, so a backfill into a nested value object (`backfill "attendee.first_name"`) was refused as "not a plain identifier" and `hecks build_wasm` failed for any domain with one. An era edge names stored-data paths that the host applies to rows; none is written into Rust. `translations` is skipped by both twins of the check (`rust/project/naming.rb` and `rust/codegen/src/naming.rs`); every other declared name is still checked.

**`hecks gate <stage> [only=a,b]` runs a stage's checks, which are now data.** The checks the
pre-push hook ran as shell are the `pre_push` stage of `lib/hecks/gate/stages.yml` (an id, a title,
the command, and what a red check means). `gate` starts them together, prints every red one, and
under `--wait` exits 1 when the run is `faulted`; the hook calls the same tool, so the list of
checks lives in one place. It is a `GateRun` aggregate on the Codebase chapter, so each run is in
the journal. `hecks gate --list` shows the stages. CI workflows are still hand-written.

**`hecks follow <domain> --stream` tails an event log.** The launcher asks again from each answer's cursor and prints every new entry as one JSON line (its payload as an object), until you interrupt it or the reader goes away; `from_now` applies to the first ask only, and each ask waits for the first new entry (the question's `wait`, 30 seconds when absent). A question is tailable when the world's `launcher` setting lists it under `streams` (`Follow` is). Without `--stream`, `follow` is the bounded poll it was.

**`docs/migrating-2-to-3.md`** collects what a 2.x project changes to move to 3.x.

**The host can refuse a caller that holds no role (`HECKS_ROLE_ENFORCEMENT=off|shadow|enforce`).** Until now a dispatch that stated no role skipped the check, and the host never passed an `actor_id`, so Governance assignments were not consulted. A `POST /dispatch` body may now carry `actor_id`; an identified caller that states no role is held to what Governance assigned them (the kernel's `check_role_via`), and unchecked only when no Governance provider is compiled in. With `shadow` an unidentified caller is dispatched as role `Anonymous`, and a refusal that would follow is logged as `would_refuse_role` while the command goes through; with `enforce` it is refused. The default is `off`, so nothing changes until a deploy sets it. Host-internal steps (the registration pipeline, the Stripe and newsletter routes) remain unchecked.

**The host can set a Reply-To on newsletter email (`RESEND_REPLY_TO`).** A site that sends from a Resend-verified address it has no mailbox for (`news@mail.example.com`) can still have replies reach a real inbox: set `RESEND_REPLY_TO` and each email carries `reply_to`. Blank or unset sends no `reply_to`, as before. The mock mailer ignores it.

**A command can declare `needs :now` (ADR 0081, first slice).** A fact the command needs from
outside the record, answered by the runtime before any `given` runs: `needs :now` fills the command's
own `now` argument with the time the clock gives. The answer is written into the arguments, so a
`given` reads it like any argument, the event records it, and a replay re-dispatches the recorded
value. `days()`, `hours()` and `minutes()` fold to seconds, in Ruby and in the Rust kernel. Rules
that need a record other than the command's own are the next slice (see the ADR).

**A launcher reads its domain once, not twice.** `exe/hecks` answered usage from `Hecks.describe`
and then, for a line that runs a verb, called `Hecks.boot`, which loaded every chapter again.
`Hecks.boot_described(described)` finishes a boot from what `describe` already loaded, and the
generated launcher calls it, so a verb call costs about a quarter less (about 1.46 s to 1.13 s of
CPU for `hecks ask word_status`). Usage lines still open no database. `Loader::Described` now
carries the `directory` it resolved. `Hecks.boot(path)` is unchanged: it is `describe` then
`boot_described`.

## [3.0.3] - 2026-10-01

**Security: `GET /members` requires an Admin or Owner.** It returned every admitted person's name, email and role to any member holding an active account cookie. It now answers 403 to a member who is not an active Admin or Owner, the same check sending the newsletter uses, and matches what `docs/running-a-rules-service.md` already said. A client that lists the roster from a plain member's cookie must use an admin's.

**Security: `uses_embryonaut_bluebook` refuses a package name that is not a plain name.** The name was joined into a path under `vendor/embryonaut_bluebooks/` with no check, so `uses_embryonaut_bluebook "../x"` loaded `*.bluebook` files from outside `vendor/` as Ruby, and in the Rust build deleted and rewrote a `rust/src/generated/<name>` directory chosen by the hecksagon. `EmbryonautBluebook.load!`, `project_rust_pipeline.rb` and `hecks-build` now refuse any name outside `[a-z][a-z0-9_]*`, the shape `hecks vendor` already accepted, before touching a path.

## [3.0.2] - 2026-09-30

**Security: `GET /newsletter/subscribers` requires an Admin or Owner.** The route returned every subscriber's email, names and status to any caller; it now answers 401 without an active account cookie and 403 without the Admin/Owner role, the same check sending the newsletter uses. A client that read the list without a cookie must send the account cookie.

**Security: `rust/host` dependencies.** wasmtime and wasmtime-wasi 47.0.3 to 49.0.1 (RUSTSEC-2026-0269 filesystem sandbox escape, 0268, 0314, 0315, 0316), rustls 0.23.43 to 0.23.45 (0285), h2 0.4.15 to 0.4.16 (0258). `cargo audit` on `rust/host` reports only the unmaintained `rustls-pemfile` and a yanked `chacha20`.

**Security: code generation refuses declared names that are not plain identifiers.** The parser accepts any characters in a quoted symbol (`attribute :"name: String, pub evil: u8", String`), and the generator wrote attribute, command, event, query and port names into the generated Rust as field, struct and function names, so a bluebook from outside the project could inject code into the crate the host compiles. `RustProjection::DomainGenerator.call` and `hecks-codegen` now refuse, before writing anything, any declared name outside `[A-Za-z_][A-Za-z0-9_]*`, with the same message from both (`Projector.unsafe_name_refusal` / `naming::unsafe_name_refusal`). Every IR in the repository passes.

## [3.0.1] - 2026-09-30

**Binding Postgres or PostgresEra without the `pg` gem now says so.** `connect_for` raises a `LoadError` naming the domain and telling the project to add `gem "pg"`; before, a `rescue PG::Error` clause evaluated `PG` while the `LoadError` propagated and replaced it with `uninitialized constant ...::PG`. `hecks project_cli` reports the missing gem as "cannot boot" instead of crashing. `hecks model_check` reports a malformed bluebook on stderr and exits 1 instead of printing a stack trace.

## [3.0.0] - 2026-09-30

**`hecks --help`, `hecks` and `hecks <verb> --help` bind no adapter.** `exe/hecks` answers usage and an unknown verb's hint from the projected bluebook alone (`Hecks.describe`, `Doors::CliRunner.usage`), in any environment: no Postgres, no `pg` gem and no `HECKS_ENVIRONMENT=memory` needed. A verb that runs still boots the domain as before; regenerate launchers with `hecks project_cli`.

**The Rust host checks every expression node a value object's invariant can use at mint time.** `include?`, `+`, `.modulo`, `.all?`/`.any?`/`.none?`, `.find`, array literals, `.match?`, `.present?`/`.blank?`, `.set?`/`.unset?`, `.split`, `.first`/`.last` and `.start_with?`/`.end_with?` were refused by name; they now evaluate with the Ruby runtime's answers, null handling and error wording (`spec/rust_host_expr_json_conformance_spec.rb` diffs the two).

**Breaking:** `Hecks::Facade` is now `Hecks::Doors` (`Surface` is `Doors::RubyDoor`, the MCP door lives beside it); `install_facade:` is now `install_doors:`. Both old names still work for one release and warn; regenerate launchers with `hecks project_cli`.

**Committed approvals enforce `host_version`.** A rehearsal in `translations/<edge>.approval` now counts only when its `host_version` has the same `major.minor` as the Hecks release the running host was built for (`3.0.0` and `3.0.9` agree; `2.9.0`, `3.1.0` and a value that is not a version do not). A patch release does not change what a mint does, so a rehearsal survives it; a minor or major one may, so it does not. Ruby (`ApprovalFile`, on boot) and `rust/host` refuse with the same message naming both versions. The host learns its release from `rust/host/HECKS_RELEASE`, which must equal `Hecks::VERSION`: the release preflight refuses when it does not, and a spec fails on drift. `approve_translation` records `Hecks::VERSION` when `host_version=` is omitted.

**Faster boot: an on-disk cache of chapter verdicts.** `MetaValidator` keeps the meta-domain's judgment of each chapter (keyed by the SHA-256 of the chapter's IR) in `hecks_verdict_cache/` under `Hecks::CacheDir`, so a second process skips re-judging the language and attached chapters (Hecks-chapter boot about 7-8s CPU to about 1.2s). The file name carries a digest of every file under `lib/` plus the Ruby and Hecks versions, so editing any validator, builder or grammar file misses; `Assembly.call` still runs every boot, and a miss judges exactly as before. The file is tagged JSON (never `Marshal`) and read only from a private, user-owned directory. `HECKS_VERDICT_CACHE=off` disables it (`spec/verdict_cache_spec.rb` covers the off path in CI; the suite itself runs with the cache on, in a per-run tmp directory). The syntax-boot cache key now also covers all of `lib/`, so a Ruby-only edit no longer serves a stale table.

**Breaking (3.0.0): `bin/` is removed; every script is a `hecks <verb>` command (ADR 0080).**
Each script is now a command on the Hecks domain, run through the launcher `hecks project_cli`
generates as `exe/hecks`. `exe/hecks` stops being a hand-written router: the command names stay,
but arguments are projected from the bluebook, so flags and argument order change. The verb for a
script is the one the 2.10 notice printed (`bin/compact` is `hecks compact <domain> [aggregates=A,B]
--confirm`). Two launcher names differ from the command's own: `mcp` runs `ServeMcp` (also
`hecks serve_mcp`) and `console` runs `OpenConsole` (also `hecks open_console`). Two consequences
reach client repositories:
- A `Makefile` or shell script `bin/project_deploy` generated calls `bin/<name>`, and stops working;
  regenerate it with `hecks deploy project <domain>`, which now writes `hecks <verb>` calls.
- A CI job, hook or doc that runs `bin/<name>` moves to `hecks <verb>`. Every script has a row in
  the ADR 0080 command table; `hecks <verb> --help` says what it takes.
- The `bin/` directory is deleted, with the 2.10 stderr notices and the comments they added to
  generated deploy files. `Hecks::ThreeZero` keeps only `FORMS`, the table of what each retired
  script became (`lib/hecks/three_zero/forms.yml`). Banners in generated files name the verb that
  regenerates them (`GENERATED by hecks project_rust`, `hecks project_parser_table`, ...), so
  `rust/src/generated/` and the other committed projections changed by those lines only.
- The README's generated `tools` region and the reference's `bin/` script table are gone; nothing
  read them.

**Breaking (3.0.0): the Hecks chapters' constants live under `Hecks::Domain`.**
`hecks.bluebook` declares `namespace "Hecks::Domain"` (a new chapter word), so `Release`,
`Codemod`, `Corpus`, `Fuzzing` and `Kernel` no longer collide with the gem's own `Hecks` module.
Code that reached a Hecks-chapter constant as `Hecks::<Name>` reaches it as
`Hecks::Domain::<Name>`.

**Breaking (3.0.0): `Hecks::Facade` is now `Hecks::Doors`.**
`Hecks::Facade` is now `Hecks::Doors` (`Surface` is `Doors::RubyDoor`, the MCP door lives beside
it); `install_facade:` is now `install_doors:`; old names work for one release and warn;
regenerate launchers with `hecks project_cli`.

**Breaking (3.0.0): `answered_by` is removed from the language.**
A `query` no longer names the port that answers it. The binding from a query to its port moves to
the hecksagon, beside the other adapter bindings, so a bluebook says what is asked and the
hecksagon says who answers. Move each `answered_by` binding into the domain's hecksagon as
`answers_query "Name"`, and declare the shape of the answer in the bluebook: the query says
`returns Name` (or `returns list_of(Name)`) for a value object of its aggregate, and every row an
adapter answers is built as that value object before it enters the domain. A query has exactly
one answer path, checked at boot: it filters the aggregate's records, or it returns a value
object and one port binds it.

**Breaking (3.0.0): two Hecks lifecycle commands are renamed.**
`Era.Admit` is `Era.Permit` (the lifecycle's `admitted` state and the request that reaches it are
unchanged), and `Release.Publish` is `Release.MarkPublished`; `Release.Verify` now also runs from
`verified`, so a repeated verification is not refused. Anything that dispatches the old names by
string uses the new name.

**Breaking (3.0.0): an era edge's approval is a committed file, `translations/<from>-<to>.approval`.**
A translation edge is approved by a JSON file beside the edge, and the host reads it at its next
boot; it is valid while its digest matches the edge. A journal approval bound to the tip still
satisfies the check, so a deployed edge approved before 3.0.0 keeps booting; a new approval is
written as the file, and a file whose digest no longer matches the edge is refused.

**Breaking (3.0.0): the gem ships `rust/` and the tooling.**
The gem's files are `lib/` whole, `rust/` (without `rust/tests/`, `rust/src/generated/` and any
`target/`), and `exe/hecks`. It is larger, and `hecks build_wasm` and the other Build commands work
from an installed gem: a build copies the workspace to `.hecks/rust/<version>/` and never writes
into the gem. Anything that read the gem's file list to leave the tooling out no longer can.

## [2.9.0] - 2026-09-28

**Feature: `POST /members/delete` soft-deletes a disabled member.**
The route was missing from 2.8.0, so a deployed 2.8.0 host answered it with the
auth gate's `Unauthenticated` 401. It mirrors `set_person_disabled`: locked against
concurrent membership writes, caller must be an active admin, the target must
already be disabled, and the row stays in the journal with a deleted flag that the
member list filters out.

**Fix: `auth::provision` reuses an existing Identity for the same issuer and subject**
instead of minting an orphan on every retry, so an interrupted first sign-in
converges on the earlier attempt's identity.

**Behavior change: Postgres and SQLite journal recovery and compaction.**
`PostgresEra` skips the boot-time `recover!` replay, replay recovery is bounded by a
per-table checkpoint, and journal compaction (ADR 0079) is available behind a gate.
Other changes since 2.8.0 are QA tooling, CI attestation and read-model reductions
(`sum`, `avg`, `min`, `max`, `percentile`, `any`, `all`).

## [2.8.0] - 2026-09-27

**Security: the Fargate host no longer runs a command or a read from an outside caller's body.**
A POST to any path the load balancer forwards, carrying `{"verb": ..., "role": ...}`
or `{"read": true}`, was read as the internal dispatch protocol and reached the kernel
with the role the caller wrote and no session check; `{"read": true}` returned the
whole current state with no role at all. The web layer's `auth_gate` never ran,
because it only sees a request that already has the Function-URL shape, and the rate
limiter did not count these bodies. The host now reads a body as the internal protocol
only from a peer on the same host (`127.0.0.1`, `::1`, or an IPv4-mapped loopback),
which is how the sidecar container in a shared task reaches it. From any other peer
the same body is an ordinary request for the path it hit, answered by the web layer's
own routes and gate. **Behavior change:** anything that sent the internal protocol to
the host over a non-loopback address, for example a container published on a bridge
network, now gets the web layer's answer for that path instead; send it from the same
host, or invoke the Lambda directly. A Lambda deployment is unaffected, since it takes
the internal protocol only through an IAM-authenticated invoke. Existing Fargate
deployments pick this up only when they move to a host built with this release.

**A PostgresEra `compute` whose source is a dotted member now fires.** The
compiled SQL tested for the source with `__s ? 'price.cents'`, a top-level key of
that literal name, so the rule never matched, the mint succeeded and the record
kept its old value. `Translation::RuleCompiler.compile_compute` now reads the
source as a path through `hecks_tr_extract`, the way the destination already went
through `path_literal`. The author's SQL still sees the whole record as `__s` and
the source's value as text under a column named by the source as declared
(`"price.cents"` for a dotted one), so SQL written for an undotted source is
unchanged. The pending example in `migration_data_safety_spec.rb` now passes, and
the client profile's `client_dotted_compute_source` rule is removed with its
probe; `bin/model_check` no longer loads `translations/` under the profile and
`ModelCheck.call` no longer takes `translations:`, since that rule was their only
reader. **Behavior change for migrated records:** a mint over an edge with a
dotted-source `compute` now converts the member instead of carrying the old value
through. The Rust host runs the same compiled SQL from the domain's exported
`ir.json`, so it picks the fix up once that IR is exported again with this
release.

**A `group_by` refuses two rows on one key path instead of dropping one.** A
read model's `group_by` leaf holds one row, and when two rows reached the same
full key path the Ruby interpreter and the generated Rust runtime both kept the
first and silently dropped the rest. Both now refuse the ask with
`InvariantViolation`, in one shared wording (`group_by_collision`) that names the
read model, its `group_by`, the colliding ids and the key path; a new
cross-runtime fixture holds Ruby and Rust to the same refusal byte for byte. A
key path that names every identity field of the grouped aggregate cannot
collide and is accepted from the declaration without a check, which covers every
`group_by` in the corpus. The fuzz oracle recomputes shared key paths from the
rows and expects the refusal, and the `client_group_by_row_drop` rule of
`bin/model_check --profile client` is gone with the bug it guarded (ADR 0061,
decision D1; ADR 0065, decision 2). **Behavior change:** a read model grouped by
a key its data does not keep unique answered with a subset before; it now
refuses from the first request after a second row reaches a key path.

**The syntax-boot cache and the Storehouse audit log no longer write into the gem's
directory.** Both lived under `<gem root>/tmp`, which is read-only on an installed
gem, so the cache silently switched off and the log silently stopped appending.
They now live under `Hecks::CacheDir`: `$XDG_CACHE_HOME/hecks`, else
`~/.cache/hecks`, else `<system temp dir>/hecks-<uid>`, each used only if it is
owned by the current user and writable by nobody else (the cache is read back with
`Marshal.load`), with a private per-process directory as the last resort.
`Storehouse::LOG_ROOT` and `SyntaxBoot::CACHE_DIR` are replaced by
`Storehouse.log_root` and `SyntaxBoot.cache_dir`, resolved on first use.
`HECKS_SYNTAX_BOOT_CACHE=off` and `HECKS_STOREHOUSE_ROOT` (the boot confinement
root, unrelated) are unchanged. Files an earlier version left under `<gem root>/tmp`
are orphaned and can be deleted. This is step 1 of ADR 0066.

**`bin/hecks_mcp_door` has a reader mode.** Whoever spawns the door can set
`HECKS_DOOR_TOOLS=readers` and `HECKS_DOOR_DOMAINS=<dir>[:<dir>...]` (ADR 0072,
decision 2). A reader door serves only `query`, `events`, `state`, `catalog`,
`describe`, `validate`, `domains`, `history` and `follow`, lists only those in
`tools/list`, and refuses `dispatch` (with `dry_run` and `steps`), `behaviors`
and any other tool with an answer that names the mode. A call's `domain:` must
resolve to one of the named directories, and is checked before anything boots,
so no other domain's Ruby is loaded. The startup warning says when the door is
in reader mode. The door refuses to start on an unknown `HECKS_DOOR_*` name, a
mode other than `readers`, reader mode without domains, domains without reader
mode, or a named domain outside the boot root. With neither variable set the
door behaves exactly as before. This limits what one spawned agent can reach;
it identifies no one, adds no token or secret, and is not authentication. The
settings sit outside `HECKS_MCP_*`, which the stdio guard keeps for the
transport alone (ADR 0062). The logic is `Hecks::McpDoorScope`.

**`bin/release` performs the whole release, and CI publishes `@hecks/client`.**
After the release PR merges, one command tags the merge commit and publishes the
gem through `bin/release_gem`. Pushing the tag starts the new
`publish-client.yml` workflow, which publishes the package to npm with trusted
publishing (no token, no one-time code, with provenance) after checking that the
tag names the package's and the gem's version; `bin/release` waits for the
version to appear on npm (every 15 seconds, up to 10 minutes; `--no-wait` skips
it). It refuses unless the checkout is a clean `main` equal to `origin/main`, the
gem and the client are at one version, and the changelog has a heading for it. It
asks RubyGems and npm what is already published and skips that, so a run that
stopped partway is finished by running it again. `--dry-run` runs every check and
build without tagging, pushing or publishing, `--gem-only` and `--npm-only`
narrow it, and `--yes` answers its confirmations. Trusted publishing is set up
once on npmjs.com, after the package exists (package settings, Trusted
Publisher, GitHub Actions, `heckslabs/hecks`, `publish-client.yml`); until then,
and when CI is down, `--npm-local` publishes from the machine with a
short-lived bypass-two-factor token from 1Password, since the account's second
factor is a passkey. The logic is `Hecks::Release::Runner`; `bin/release_gem`
still works alone.

## [2.7.0] - 2026-09-27

**The Rust host rate-limits public writes, on by default.** `POST /registrations`
and `POST /newsletter/subscribers` are limited per client address (10 subscribes
and 15 registrations an hour by default) and answer 429 with `Retry-After` past
the limit. The address is the TCP peer unless the request came through a trusted
proxy, in which case `X-Forwarded-For` is walked from the right, so a typed
leftmost entry is never used. Trust is set with `HECKS_TRUSTED_PROXIES`,
`HECKS_TRUSTED_PROXY_HOPS`, and `HECKS_PROXY_AUTH_HEADER` with
`HECKS_PROXY_AUTH_SECRET`; `HECKS_RATE_LIMIT=off` turns it off. **A deploy behind
a proxy or load balancer must set the trust variables**, otherwise every visitor
shares the proxy's bucket. The host logs `rate_limit_untrusted_proxy` when it sees
that shape. State is per process, so the effective limit is per task.

**The host's payments key store no longer has a built-in secret name.**
`PAYMENTS_ACCOUNT_SECRET_ID` is now required on AWS when checkout is enabled, and
the host refuses to boot without it instead of falling back to a fixed name. The
webhook description sent to the payment processor is a new setting,
`PAYMENTS_WEBHOOK_DESCRIPTION`, defaulting to `<HECKS_DOMAIN> website`. The host
also serves two public seat reads, `GET /events/seats` and
`GET /events/<slug>/seats`, returning capacity, seats taken and seats left from
the one seat-holding table in Rust, so a site no longer needs its own copy of the
rule.

**`@hecks/client` is a JavaScript package for the host protocol.** `packages/hecks-client`
holds `HostClient` (`read`, `dispatch`, `apply`), the answer readers `text`,
`whole`, `optionalWhole`, `instancesOf` and `refusalOf`, a resilient fetch with
retry and a last-good fallback, a client for the host's `/payments/connection`
routes with the pasted-keys parser, and a verifier for the account token the host
mints. The domain name, service URL and cookie name are parameters, and no role is
sent unless the caller sets one. Its version tracks `Hecks::VERSION`;
`bin/release_gem` refuses to release when they differ, and a `client-contract`
workflow runs the package against a live host.

**Vendoring, the gem-pin check, the schema dump proof and the boot fix move into
Hecks.** `Hecks::Vendoring` and `Hecks::EmbryonautBluebook.vendor!` (command line:
`bin/vendor_bluebook`) pin one package at a release tag or commit, write
`VENDORED_COMMIT` and, for a release pin, `bluebook.lock`, and refuse a downgrade or
a storage-shape change on a patch bump; the loader's error now names the command.
`Hecks::Release::GemPin` refuses a Gemfile or lockfile that resolves Hecks from a
path or git source and checks the version exists on the registry.
`Hecks::Ports::Persistence::PostgresDump` dumps one schema, restores it into a
scratch database and compares row counts, with the password kept out of argv.
**Fixed:** `Hecks.boot` now loads the era plugin when a hecksagon binds
`PostgresEra`. Before, a domain that did not require the plugin first booted with
its era gates (including the superuser write-fence refusal) silently missing.

**Worlds can declare `default_database` and `default_adapter`.** They apply a
persistence adapter and a database to every aggregate and chapter that does not
name its own, replacing the same block repeated per chapter. A chapter's own bind
or `database` still wins, an environment overlay replaces either default, and a
world that names neither behaves as before. `examples/compliance` uses both.

**The deploy projections gain opt-in hosting tooling.** `hosting_scripts true` under
`deployed_to("AwsFargate")` adds `deploy-service.sh`, `smoke-after-deploy.sh`, a
`hosting.mk` that pins the Hecks release the image is built from, and an
`expected-era` list; `bin/check_era <url> <file>` compares a host's `GET /version`
with it. `smoke true` adds a generic smoke harness and workflow template, and
`bin/smoke_http` checks that a receiver refuses an unsigned, mis-signed or altered
delivery and answers a repeat idempotently. A `preview` setting generates
`preview.yaml` and `preview.sh` for one isolated stack per branch. A block inside
a bind's world settings is now recorded as a nested hash instead of being ignored.
Nothing changes for a world that opts into none of them. `bin/shape <dir>` prints
the era label of every domain in a directory.

**Removed.** `deploy/banking/` and the production overlay under `examples/banking`
are gone: that recipe describes a live stack that shares another stack's network
and database, so it lives with that stack's owner, and `examples/banking` stays the
generic deploy example. `bin/rust_coverage` no longer carries a fallback that
derived a manifest from source; every generated module ships a `manifest.json`.

**Client names are gone from the tree.** Comments, tests, fixtures, corpus values,
ADRs and this file no longer name any client project; where a fixture needed a
domain name it now uses a neutral one. Released entries below are reworded to say
"a client site" without changing what they record.

**`bin/model_check` loads every `*.hecksagon` in a domain directory, not only the
first.** It picked the alphabetically first one, so a domain that split its
wiring across files (a context map beside its own) was checked against part of
its wiring, and a `projected_by` in a later file was invisible to the client
profile's native-read-model rule. A real boot loads all of them, and now so does
this tool. Two corpus domains, `nested_pieces` and `tenant_ledger`, each had a
second hecksagon that was being ignored; both stay clean with it loaded.

## [2.6.0] - 2026-09-26

**`bin/model_check --profile client` refuses three constructs that answer wrongly
without refusing.** A `group_by` that does not cover its aggregate's whole
identity (rows sharing a key path are silently reduced to the first, on every
adapter, ADR 0061), a rooted read model over an aggregate `projected_by`
`SqliteProjection` (SQL when the projection is current, the in-process loop when
it is not, with no check that they agree, `docs/1.0-readiness.md` known gap 2),
and an era translation `compute` with a dotted source (never fires, so the mint
succeeds and the record keeps its old value). Each is an error finding, opt-in
through `ModelCheck.call(profile: :client, translations:)`, and a run without the
flag is unchanged. Nothing is fixed: the profile stops a client domain reaching
the bug unnoticed, and a probe per rule in `spec/model_check_client_profile_spec.rb`
fails when its bug is fixed, naming the rule to delete. Under the profile the
tool also loads a domain's `translations/` directory, which it never read before.

**The status documents match the code again, and their links are checked.** The
README said read models had no generated Rust path and that the query language
had no aggregation, while `read_model` ships `count`, `median` and `group_by` on
both runtimes and Rust runs a proven subset of read models. It also said the
fuzzer was Memory-only in one place and Memory, Sqlite and Postgres in another,
and called the reference-hop query question open after it was resolved. Those,
the "16 pinned fixtures" count (the set is every file under
`spec/corpus/rust_conformance/`), and `docs/1.0-readiness.md`'s pre-tag title
are corrected. Two links that pointed at moved files are fixed, and
`spec/status_docs_links_spec.rb` fails when a relative link or in-page anchor in
`README.md`, `CONTRIBUTING.md` or `docs/1.0-readiness.md` stops resolving.

**The README states the current release, and a spec keeps it honest.** Its
Status line and Project status section said `1.0.0` while releases had reached
2.5.1. Both now read `Current release: x.y.z`, and
`spec/readme_version_spec.rb` fails when either differs from `Hecks::VERSION`,
so a version bump can't ship with a stale README. `CONTRIBUTING.md`'s release
steps name the README update.

**ADR 0025 no longer reads as both landed and unbuilt.** The README's "Planned
or research only" list still carried it as "Accepted, not yet implemented" while
"Project status" (and `docs/dsl-work-slices.md`, every slice DONE) said it had
landed. The stale entry is gone and the ADR's own Status line now reads
"Accepted — implemented".
`spec/readme_planned_adrs_spec.rb` fails if an ADR linked from that README list
is marked implemented in its own header.

**The status documents no longer claim spec counts.** The README cited two
different rspec example counts, neither of which matched the suite, and
`docs/1.0-readiness.md` carried pass/total figures from a past run. They now say
"the whole suite" and leave the number to the runner.
`spec/status_docs_no_spec_counts_spec.rb` fails if a count comes back in
`README.md`, `CONTRIBUTING.md` or `docs/1.0-readiness.md`.

**The two stdio MCP servers now refuse to run over anything but stdio, and say
what they do not protect.** `bin/hecks_mcp_door` and `bin/hecks_query_ir_mcp`
were stdio-only by convention and by README. `Hecks::McpStdioGuard` now
enforces it before either server loads anything: it refuses an argument other
than `--stdio`, any `HECKS_MCP_*` variable except `HECKS_MCP_TRANSPORT=stdio`, and
an IP socket as stdin or stdout (what a `socat` or `inetd` wrapper hands a
process). A pipe, a terminal and a Unix-domain socket still work. At startup each
server writes a warning to stderr (never stdout, which carries the protocol):
identity is self-asserted, the door's readers and `query` take no role, and
`domain:` boots real Ruby. Nothing authenticates a caller; the new ADR 0062
(proposed) says what a network transport would need first.

**`query_ir_duplicates` no longer loads Ruby from outside the project root.** Its
`domains:` argument is confined to `Hecks::Storehouse::BOOT_ROOT` the way the
door's `domain:` already was; before, any directory's `bluebook/*.bluebook` files
were `Kernel.load`ed. A relative directory now resolves against that root rather
than the server's working directory, which is the same place when the server is
launched from a checkout's root.

New specs cover what the bus does with no caller bound: a role-gated command is
refused for `dispatch`, `dry_run`, a batch and the qualified spelling, a blank
role is not read as no restriction, and the readers and `query` run with no role
check at all (documented behavior, now specified). `Storehouse.confine!` gained
its first direct specs.

**CI now fuzzes the whole corpus on SQLite and Postgres, and `bin/fuzz --adapter
postgres` boots every domain.** `bin/fuzz` in CI ran on the Memory adapter only.
Two new jobs beside `checks_fuzz` run the same sweep through a real SQLite
database (`checks_fuzz_sqlite`, 6 seeds per domain) and a real Postgres
(`checks_fuzz_postgres`, 3 seeds of 20 steps per domain, one process against one
server). The Postgres run found a real defect the first time it covered every
domain: when a directory held two `.hecksagon` files (the `qa` domain's
`context_map.hecksagon` beside `quality_control.hecksagon`), each one rewrote the
same `hecks_fuzz_postgres.world`, so the last file's names replaced the first's
and Governance booted bound to Postgres with no database. The worlds are now
written once per directory, naming every hecksagon block in it, the way the
PostgresEra mode already did. `spec/adapters/query_hop_agreement_spec.rb` now
also covers PostgresEra: a reference-hop query (`owner/field`) answers the same on
Sqlite, Postgres and PostgresEra as on Memory, and `docs/future-features.md` no
longer lists that as an open question.

**PostgresEra's three audited data-loss fixes now each have a real-Postgres
regression spec.** The 2026-08-10 audit's era-migrated delete, rekey-digest and
dotted-compute defects were fixed, but only the delete had a spec against a real
Postgres; the other two were pinned only by database-free unit specs.
`migration_data_safety_spec.rb` adds the missing coverage and runs in the
Postgres CI shards: a delete survives a second mint; a rekey SQL or backfill
default edited after approval refuses the mint and mints nothing, while the
approved edge still mints; and Layer 2 of the audit is fed the rows a real
compiled head produces, so a dotted compute keeps its sibling member and a
compiled edge that loses one is refused. `spec/exporter_spec.rb` now pins the
backfill half of the approval digest too. Writing the dotted-compute spec turned
up a gap that is recorded, not fixed: a compute whose source is a dotted member
(`compute "price.cents", ...`) never fires in the compiled SQL, so the mint
succeeds and the record keeps its old value. It is a pending example that turns
red when it is fixed. `docs/future-features.md` now lists what the audit's
tracking still has not re-checked independently.

**The whole banking corpus now replays byte-for-byte identically on Ruby and
Rust, and CI holds it there.** `spec/rust_conformance_spec.rb` replays
`spec/corpus/banking.json` in full against the
Rust binary as well as the small per-construct fixtures. Doing so found two
refusals Rust worded differently from Ruby, both fixed in Rust. A multi-field
value object offered as a bare scalar, array or number now refuses
`name is a PersonName — pass its fields as an object, not "Ada"`, naming the
caller's attribute and the type, where Rust said
`PersonName expects an object, got "Ada"`. A read model asked for a root record
that does not exist now refuses `no Account with reference "acct-1"` where Rust
said `no Banking::Account with id "acct-1"`. Events, instances, sagas,
reactions and refusal counts already agreed.

**The whole chess corpus is held to Ruby/Rust conformance, with a refusal
fixture beside it.** `chess` already had a Cargo feature, generated Rust and a
pinned fixture; `spec/rust_conformance_spec.rb` now also replays
`spec/corpus/chess.json` in full through the compiled binary and compares it
with Ruby byte-for-byte. A new `chess_refusals.json` fixture covers the paths
that single clean game never reaches (entity `given`s, value-object invariants,
closed-set admission, a missing record, lifecycle refusals). Ruby and Rust
already agreed on all of it. ADR 0063 (a draft) weighs whether the
framework/grammar chapters should get Cargo features of their own.

**`bin/bench` measures throughput and latency.** It dispatches a fixed, valid
command workload (the pizzas and banking examples) against the Ruby runtime on
the Memory, Sqlite, Postgres and PostgresEra adapters and against the native
Rust binary (through `rust --serve`), and reports commands per second with p50
and p99 latency, the median of several fresh boots. Postgres is optional: with
no server reachable those targets are skipped with a message and the rest run.
[`docs/benchmarks.md`](docs/benchmarks.md) says how to run it, publishes a
baseline with the hardware it was taken on, and lists what the numbers do not
show. It is a measurement, not a gate, and nothing in CI runs it.
`Fuzzing::IsolatedBoot.call` takes a `scratch:` option so the Postgres adapter
can run in a schema of the caller's choosing instead of the fuzzer's shared one.

## [2.5.1] - 2026-09-26

**Projecting a framework chapter no longer leaves a dangling `pub mod merged;`,
and `bin/project_wasm` no longer dirties the tracked tree.** A framework chapter
attached to a target domain shares a directory name with the checked-in
standalone domain of the same name. The chapter never gets a `merged.rs`, but its
`mod.rs` kept a `pub mod merged;` trailer while the standalone domain's
`merged.rs` was still on disk, so the crate failed to build (E0583) until a
second run. `bin/project_rust` now tells the generator whether it writes a
`merged.rs`. `bin/project_wasm` projects and builds in `tmp/project_wasm/rust`
(`HECKS_RUST_DIR`) instead of the real `rust/` crate, so the checkout is left
clean.

**An era mint no longer stalls on a long chain.** rust/host reads the era chain
(the audit before a mint, and each head it builds) as one `WITH` statement with a
CTE per translation edge. Postgres inlined those CTEs and copied every previous
edge's expression into each read of `state`, so the statement grew exponentially
with the number of eras: a real six-edge chain planned to about 70,000 sub-plans
and, over a journal of 300 rows, ran for minutes and was killed for memory (JIT
made it far worse). Every CTE in the chain is now `MATERIALIZED`, so planning and
running grow linearly with the number of edges; the rows are identical. A
deployment with a chain of six or more eras that could not mint its next era can
now.

**rust/host logs each boot phase.** Around every boot step (database connect,
schema setup, era resolution, approval check, the audit and each aggregate in it,
the mint and each head it compiles, the snapshot fill, the commit, and the
listener) it logs a `boot_phase` line with `event: "start"` and another with
`event: "end"` and `elapsed_ms`, so a hang shows as a start line with no end
after it. The lines carry identifiers only (phase, aggregate storage name, era).

**rust/host now writes structured logs to stdout.** One JSON object per line:
`boot` at startup, `request` for every HTTP request (method, path without the
query string, status, milliseconds; `error` level for a 5xx), `command` for every
dispatched command (verb, role, events emitted, refusals; never the facts), plus
`dispatch_failed` and `cross_domain_delivery_failed` on failures. On Fargate the
task's `awslogs` driver ships stdout to CloudWatch, so the domain container's log
stream is no longer empty and Logs Insights can filter on the fields, for example
`filter msg = "command" and accepted = 0`.

## [2.5.0] - 2026-09-26

**Two new capabilities, `registrations` and `payment_connection`, and rust/host
reads them.** A chapter can declare `provides "registrations", schedule:
"Event.Schedule", request: "Registration.Request"` and `provides
"payment_connection", connect: ..., reconnect: ..., disconnect: ..., suspend:
..., resume: ..., enable: ..., disable: ...` (each naming a real command of that
chapter). `bin/project_rust` exports them to `ir.json` as `registrations` (with
`event_aggregate` and `registration_aggregate`) and `payment_connection` (with
`aggregate`), the same way `payments` is exported, and omits each key when
nothing attached provides it. rust/host now takes the event, registration and
payment-connection names from them instead of literals, and falls back to the
previous names (`<Domain>::Event.Schedule`, `Registration.Request`,
`PaymentConnection.*`) when a domain declares neither, so a host whose domain
declares nothing behaves exactly as before. Declaring either capability does
not change a domain's storage shape, so it does not mint an era. A hecks gem
older than this release refuses either `provides` line ("no capability the
language knows"), so a consumer must upgrade to 2.5.0 before declaring them.

**An internal kernel error is now a failed command, not an accepted one.**
When the kernel cannot run a step at all (for example `invalid seed:
Registration.status: missing from JSON args`, from a stored snapshot that no
longer matches an aggregate's shape) it answers with a top-level `error` and no
`refusals`. rust/host read the missing `refusals` as an accepted command: it
journaled the failed command and saved the empty result as the new snapshot, so
the next successful write left a snapshot holding only its own instances. Now
`dispatch::handle` (and so `handle_routed`, `handle_facts` and the `/dispatch`
route) returns an error and rolls back: nothing is journaled, the snapshot,
sagas and era mirrors are untouched, and the route answers 500 with the
message. `read` and `query` fail the same way instead of returning an empty
world. A refusal (an entry in `refusals`) and a normal accept behave exactly as
before.

**An archived registration frees its seat.** A registration whose `status` is
`archived` no longer counts against its event's capacity, whatever its Payment
says, so `seats_left` and the 409 `this event is full` answer follow. A
registration holds a seat when its Payment is pending, succeeded, refunding or
disputed and it is not archived; one with no `status` at all counts as active,
so a domain whose Registration has no lifecycle behaves exactly as before.
`GET /registrations` rows carry a `status` key when the registration has one
and are unchanged when it does not.

**Minting an era fills lifecycle defaults into the stored snapshot.** rust/host
keeps a snapshot of every instance and seeds each dispatch from it. When an
aggregate gains a lifecycle, the snapshot's existing instances lack the new
field, and the generated code refuses them (`invalid seed: Registration.status:
missing from JSON args`). The era mint now gives every seeded instance that
lacks its aggregate's lifecycle field that lifecycle's default, inside the mint
transaction, under the same advisory lock a dispatch holds. Instances that
already carry the field, and aggregates with no lifecycle, are left alone.

## [2.4.0] - 2026-09-26

**A value object declared in a sibling aggregate is read as a value object.**
A value object declared on one aggregate and used as an attribute type on
another aggregate of the same chapter (`attribute :site_reference,
SiteReference`, with `SiteReference` declared on `ManagedSite`) was read by the
IR assembly as `Reference<SiteReference>`, and the SQL query builders never
found it: on Postgres and PostgresEra a `where(site_reference: :site_reference)`
matched nothing in every call shape, while Memory answered correctly. The
attribute is now read as the value object it names, and the query builders
resolve it chapter-wide the way coercion already did, so where-queries on it
work on every adapter. Declaring a local copy of the value object was the
workaround; it is no longer needed. **Behavior change for deployed domains:**
the IR of any domain that uses this pattern changes, so its era hash changes.
A deployed PostgresEra domain gets a new era on first boot after upgrading.

**An unsupported method call in a rule is refused when the bluebook loads.** A
call the expression language has no node for, written in an `invariant`,
`given`, `ensures` or a policy `where`, for example `value.between?(100, 599)`,
used to load and then raise `EvaluationError: cannot read "between?(100, 599)"`
on the first dispatch. It now raises `DSL::Malformed` at load, naming the
expression and the supported alternative (comparisons joined with `&&` / `||`,
e.g. `value >= 100 && value <= 599`). A path containing a parenthesis, comma or
whitespace is what marks a call; bare `.nil?` is deliberately not refused and
still loads. **Behavior change:** a bluebook that used such a call loaded before
and is refused now; rewrite the rule.

**rust/host takes Stripe payments in an embedded Checkout form.** For an
enabled Stripe connection, `POST /registrations` opens the Checkout Session
embedded rather than hosted, so the guest pays inside the site. The response is
`{registration_id, embedded_checkout: {client_secret, publishable_key,
stripe_account, session_id}}` with no `checkout_url`; the mock walkthrough still
answers `{checkout_url, registration_id}`. The request pins
`Stripe-Version: 2026-04-22.dahlia` and sets `ui_mode=embedded_page`. The
session is opened before anything is written: a Stripe failure answers 502
`payments are temporarily unavailable` and leaves no Payment or Registration
behind, so a retry does not strand an orphan. **Behavior change for hosts and
sites:** a Stripe plan no longer returns a hosted URL, and the site must mount
the embedded form. New config `STRIPE_PLATFORM_TEST_PUBLISHABLE_KEY` and
`STRIPE_PLATFORM_LIVE_PUBLISHABLE_KEY`; an enabled connection whose mode has a
secret key but no publishable key is paused (503) before any write.

**rust/host lets a business use its own Stripe account, without Connect.**
`POST /payments/connection/direct` (Owner only) records the connection with the
reserved `account_ref` `self`. It takes either `{mode}`, for keys set in the
environment (`STRIPE_ACCOUNT_TEST_KEY`, `STRIPE_ACCOUNT_LIVE_KEY` and their
`..._PUBLISHABLE_KEY` pairs), or `{secret_key, publishable_key}` pasted on the
Payments page. Saving verifies the key with Stripe, creates the webhook
endpoint in the business's own account, and stores keys, signing secret and
webhook id in one AWS Secrets Manager secret (`PAYMENTS_ACCOUNT_SECRET_ID`;
`PAYMENTS_WEBHOOK_BASE_URL` sets the webhook origin, defaulting to `SITE_URL`),
never in the tenant schema, a response or a log line. Disconnect removes the
webhook and the saved keys. `GET /payments/connection` gains `can_save_keys`.
Environment keys win over saved ones. Connect connections behave as before.
**Behavior change for hosts:** the public mock webhook secret is now refused
(500) whenever any real Stripe credential is configured or saved and no
`STRIPE_WEBHOOK_SECRET` or saved signing secret exists.

**rust/host refuses registrations for a full event.** `POST /registrations`
answers 409 `this event is full` after the 404 and 422 checks and before any
Stripe call or write. A seat is held by a Registration whose Payment is
`pending`, `succeeded`, `refunding` or `disputed`; `failed`, `refunded` and
`charged_back` give it back. Embedded sessions expire 31 minutes after creation,
so an abandoned checkout releases its seat through the existing
`checkout.session.expired` webhook. An event with no readable capacity is not
blocked; a mock registration has no expiry and holds its seat until settled.

**The host's account cookie name is configurable, and its default changed.**
`HECKS_SESSION_COOKIE` names the cookie (letters, digits, `_`, `-`, `.`; boot
refuses anything else). **Behavior change for hosts:** the default is now
`hecks_session`, not a client-named cookie. A host that sets nothing logs its
existing sessions out on upgrade; set `HECKS_SESSION_COOKIE` to the old cookie
name to keep them.

**The glossary tags sensitive fields.** Fields marked with
`has_phi(readable_by:)` in a `.hecksagon` now read `medications (text, PHI)` and
each aggregate lists them under **Handled as sensitive**, with the role that
reads them unredacted. `Projector.call(:glossary, ..., options: {markings:
[...]})` takes the markings and `bin/project_glossary` passes the booted
registry's own; with none the Markdown is unchanged. Also fixed: the HTML
renderer dropped every list caption, so "Always true" rendered as an empty
paragraph.

**Tooling: `bin/project_deploy` and committed client code.** `bin/project_deploy`
takes `--out=<dir>` to write a recipe beside the client, and
`--environment=<name>` to load `<domain>/bluebook/environments/<name>.world`
over the base world (a missing overlay aborts). `examples/banking`'s base world
is now generic; its live stack names moved to
`environments/production.world`. Removed: a client's committed deploy directory, the committed
`rust/src/generated/` snapshots of the client and vendored-chapter domains, the
per-client Cargo features, and the corpus
machinery that only accounted for external domains (`Corpus`'s `:external`
check kind and vendored-chapter helpers). A client's own build regenerates its
Rust with `bin/project_wasm`, which does not need them. The client-named web module is
now `web/registrations.rs`.

**QA tooling.** The ledger's Governance chapter has a world, so
`bin/run qa/bluebook` boots again after 2.0.0 (#824). Persistence-parity
sweeps read a PostgresEra binding passed through a local variable (#825),
carry the vendored bluebooks a target names into the isolated copy (#831), and
ask generated queries about values the sequence stored, so a where-query on a
written row is exercised rather than matching nothing on every adapter (#835).

**The unsubscribe link is signed.** Every email that carries an unsubscribe
URL (each recipient of an issue send, `send-test`, and the `List-Unsubscribe`
header on the confirmation email) now links to
`{SITE_URL}/newsletter-unsubscribed.html?email=<encoded>&token=<token>`. The token
is a purpose token (`newsletter-unsubscribe`, claims `{email}`, 730-day
lifetime, keyed by `SESSION_SECRET`); the purpose keeps it apart from a confirm
token, so neither verifies as the other. `GET /newsletter/subscribers/unsubscribe`
now requires a token minted for that exact address and answers 403 (`this
unsubscribe link is invalid or has expired`) for a missing, wrong,
other-address or expired one; an already-unsubscribed address still answers 200.
An issue send or `send-test` with no `SESSION_SECRET` is refused with a 503
before the issue is marked sent. **Behavior change for hosts:** an unsubscribe
link from an email sent before this change (bare `?email=`) now gets a 403.

**Confirmation emails are rate limited per address.** `send_confirmation` mails
one address at most once per 10 minutes (case-insensitive). Inside the window a
subscribe or registration still succeeds and the subscriber stays `pending`, but
no email is sent and one line is logged without the address. The limiter is
in-memory, so it is per process; it holds at most 10,000 addresses and, when
full, sends nothing to a new address rather than forgetting a live one. With
`RESEND_MOCK=1` the same limit applies, so repeat signups of one address in a
local run send one mock email per 10 minutes.

**rust/host no longer confirms a subscriber itself.** `POST
/newsletter/subscribers` used to dispatch the `confirm` verb right after a
Subscribe or AddName whenever the subscriber was still `pending`. It now
dispatches only Subscribe or AddName and reports the resulting status.
**Behavior change for hosts:** a new subscriber now stays `pending` until they
follow the confirm link, and only confirmed subscribers receive an issue.

**The confirm link is emailed, and signed.** A new footer subscriber is sent a
link carrying a signed, expiring token minted for exactly that address (the
existing purpose-token helper, keyed by `SESSION_SECRET`), through Resend
(`RESEND_API_KEY` + `RESEND_FROM`, or `RESEND_MOCK=1`). `GET
/newsletter/subscribers/confirm` now requires that token and answers 403 for a
missing, wrong or expired one, so an address alone no longer confirms anyone.
Sending is best effort: an unconfigured or failing mailer is logged and the
subscriber stays `pending`; the signup never fails.

**Registrants who tick the newsletter box.** When `Registration.Request` declares
a `news_signup` argument, `POST /registrations` also sends flat `news_signup`,
`email`, `first_name` and `last_name` to it (a reaction reads only top-level event
fields, never one nested in `attendee`), and after a successful registration
emails the same confirm link if the address is now a pending subscriber. The
subscribing itself is a reaction the domain declares.

## [2.3.0] - 2026-09-25

**Sending a newsletter issue is a declared capability.** A chapter can declare
`provides "newsletter_issues", send_issue:, record_delivery:` (the command that
marks an issue sent and the one that records each delivery), beside
`provides "newsletter"`. It is a separate capability so a chapter that only
takes signups declares nothing more. The Exporter qualifies the verbs and
`bin/project_rust` writes them to `ir.json`'s `newsletter_issues` key; a domain
without that key serves no send route.

**rust/host sends the newsletter.** `POST /newsletter/issues/:slug/send` marks
the issue sent and mails every confirmed subscriber; `.../send-test` mails one
address without touching the issue. Both need a signed-in Admin or Owner
(the host's session cookie). Email goes through Resend (`resend.rs`) with
`RESEND_API_KEY` and `RESEND_FROM`; `RESEND_MOCK=1` logs instead of sending.
A deploy can name the key's Secrets Manager secret instead (`RESEND_SECRET_ID`,
`{"api_key": "..."}`), fetched at cold start; if it cannot be read the host
still boots and the routes answer 503.
With neither set the routes answer 503 before anything is marked sent, unlike
checkout, which mocks by default: marking an issue sent cannot be undone.

## [2.2.0] - 2026-09-25

**Payments is a declared capability.** A chapter can declare
`provides "payments", initiate:, succeeded:, failed:`: `initiate` a command
on the paying aggregate, the two processor verdicts hecksagon port operations
(spelled `Aggregate.Port.Operation`; the first shipped use of the
`:port_operation` kind from 2.1.0). `Registry#payments_provider_for` resolves
the provider, `Exporter.payments` qualifies the verbs and names the aggregate,
and `bin/project_rust` writes them to `ir.json`'s `payments` key. rust/host's
checkout, registration-payment and webhook routes read that key instead of the
`Payments::Payment.*` literals.

**Behavior change for hosts.** A domain whose IR has no `payments` key now
serves no checkout, registration-payment or webhook routes. Before deploying a
host built from this release, the vendored payments bluebook must declare
`provides "payments"` (embryonaut_bluebooks #10). On the Ruby side this
release is required to load such a chapter at all: 2.1.0 refuses
`provides "payments"` as an unknown capability. Declare it in the same
`.bluebook` file as the `Payment` aggregate; each file is validated on its own.

**Fixed: the Rust parser refused the newsletter and payments capability keys.**
The language grammar listed only the authorization, membership and identity
`provides` keys, so `hecks-parse` rejected `provides "payments"` (and would
have rejected `provides "newsletter"`) even though Ruby accepted them. The
grammar now declares `subscribe`, `add_name`, `confirm`, `unsubscribe`,
`initiate`, `succeeded` and `failed`, and a new spec holds the grammar and
`Capabilities::CONTRACTS` together.

**rust/host.** Added `POST /members/role`, which changes the role of an
already-admitted person (#810).

## [2.1.0] - 2026-09-25

**Newsletter is a declared capability.** A chapter can declare
`provides "newsletter", subscribe:, add_name:, confirm:, unsubscribe:`
(each a command on one subscribing aggregate), the same declared-not-named
shape `membership` and `identity` already are. The Exporter qualifies the
verbs and `bin/project_rust` writes them to `ir.json`'s `newsletter` key.
rust/host's `web/newsletter.rs` reads that key instead of the
`Newsletter::Subscriber.*` literals.

**Behavior change for hosts.** A domain whose IR has no `newsletter` key now
serves no `/newsletter/*` routes. Before deploying a host built from this
release, the vendored newsletter bluebook must declare
`provides "newsletter"` (embryonaut_bluebooks #6). On the Ruby side this
release is required to load such a chapter at all: 2.0.0 refuses
`provides "newsletter"` as an unknown capability.

**`provides` verbs may name a hecksagon port operation.** A capability
contract can declare a key of kind `:port_operation`, spelled
`"Aggregate.Port.Operation"`. The chapter checks the spelling and that the
aggregate is its own; `Registry#verify!` checks the operation exists on the
hecksagon that declares the port and refuses boot with a `WiringError`
otherwise. No shipped capability uses the kind yet.

**rust/host.** Added `GET /members` (JSON) and the Stripe Connect payment
connection routes. The accounts, newsletter and checkout/registration glue
moved out of `web.rs` into `web/accounts.rs`, `web/newsletter.rs` and
a client-named web module, with no behavior change.

## [2.0.0] - 2026-09-24

**Breaking: `uses_framework` / `uses_embryonaut_bluebook` load bounded
contexts.** Framework and embryonaut_bluebooks chapters never write
`bounded` in their own files — the consuming `uses_*` word marks them.
A bounded chapter wraps in its own module (`Domain::Aggregate`); Object
shortcuts (`Person.Admit`) are not installed, so two BCs can both declare
`Person` without colliding. Folder-spread `.bluebook` files of the SAME
chapter still merge as one chapter; they are not BCs.

**Breaking: a consumer can mark their own chapter `bounded`.** That mark
always requires a `translates` ACL or boot refuses. Any field can be
mapped; the BC does not list which. rust/host does not build Identity
(or any other BC) payloads — mapping lives on the hecksagon.

**Breaking: attaching a BC without its sibling hecksagon refuses boot.**
`uses_framework "Governance"` needs `Hecks.hecksagon "Governance"`;
`uses_embryonaut_bluebook "membership"` needs `Hecks.hecksagon "Membership"`.
That sibling — and every `translates` ACL — lives in `context_map.hecksagon`.
Same-name `Hecks.hecksagon` blocks from every `*.hecksagon` file merge into
one hecksagon per domain (order-independent). Any field can be mapped; the
BC does not list which. rust/host does not build BC payloads.

**Identity is recognised by `provides "identity"`, not the literal name.**
Same declared-not-named shape authorization/membership already are.
`ExternalIdentifier.Link` takes `identity`, never `identity_id` and never
`to:`.

## [1.5.1] - 2026-09-19

**Fixed: `Compliance` framework member missing from the packaged gem.**
`lib/hecks/framework/bluebook/compliance.bluebook` was a symlink out to
`examples/compliance/bluebook/compliance.bluebook` — a symlink pointing
outside `lib/` never survives `gem build` (RubyGems drops it, warning
"not supported on all platforms"), so 1.5.0 as published had no
`Compliance` at all (`Framework.members` listed only `ConsoleSettings,
Governance, Identity, Privacy`); any real consumer's own
`uses_framework "Compliance"` refused to boot. Fixed by swapping which
side is the symlink: the real content now lives in `lib/` (the tree the
gemspec actually packages), and `examples/compliance/` symlinks back to
it, not the other way around. Verified against a real, locally-built
gem: `compliance.bluebook` is a real 221-line file inside the unpacked
package now, not absent.

## [1.5.0] - 2026-09-19

**A new `Privacy` framework member: attribute-level sensitivity marking,
read-side redaction, and cryptoshredding.** `uses_framework "Privacy"`
attaches `Marking` (`domain`, `attribute_path`, `category`,
`readable_by`) — declared by chaining off the marked attribute itself
inside a `.hecksagon` file, `Registration.attendee.medications.has_phi(
readable_by: "Privacy officer")`, never inside the domain's own
`.bluebook` (a domain never states its own attributes are sensitive;
that's a wiring decision, the same restraint a persistence bind already
holds to). `Facade::Handle`'s own `#[]`/`#to_h`/dot-reader now redact any
marked field to the literal `"[redacted]"` unless the ambient caller
holds a live Governance grant of that marking's own `readable_by` —
always the strong, identified-actor check, never the weak string-only
fallback a command's own `role` allows an unidentified caller. A
declared marking takes effect once a dispatcher exists
(`Runtime::Loader.boot`'s own `seed_privacy_markings!`, idempotent
across reboots, the same shape `redrive_outbox!` already has).
`Compliance` gains a third review shape, `PrivacyReview`, reached via a
`translates` reaction to `Marking.Marked`. Also new: `Privacy::SubjectKey`
(`Issue`/`Shred`), a right-to-erasure mechanism satisfied by destroying
an external encryption key rather than rewriting or deleting a single
event.

**A durable `Tenancy` bounded context, and a new `translates` wiring
word.** `Tenancy::Tenant` (`Register`/`Suspend`/`Reactivate`/`Retire`,
`Active`/`BySlug` queries) is the durable, reactable fact `Deploy::Tenant`'s
own header long deferred — booted centrally, never `uses_framework`-attached
(a single-row-per-tenant copy folded into every tenant's own boot would
defeat the point of a cross-tenant list). `translates "Name" do on
Foreign::Event; trigger Local::Command, with: {...}; end` is a new
`.hecksagon`-context word for a cross-domain reaction declared as a
wiring decision rather than a `.bluebook` `policy` block — builds the
exact same `Policy` IR a `policy` block would (no new runtime
semantics), with a Rust parser mirror. Also: `Deploy::Tenant.port
"TenantProvisioning"` plus a real driven port replaces
`bin/project_tenant`'s inline file IO/boot with a real dispatch; a
real, previously-unguarded `Registry#add_bluebook` name-collision bug
is now caught (only when contributing files resolve to more than one
package root, so the self-hosted grammar's own legitimate multi-file
accumulation is untouched). Found and fixed along the way:
`bin/model_check`'s own `deaf_policy` check had no acknowledgment
mechanism for a `translates`-shaped reaction (a local target, a
foreign event) — `global_emitted_events:` closes it, checked only as
a fallback, so every pre-existing call site is unaffected.

**`uses_embryonaut_bluebook` proven Rust-conformant** (docs/decisions/0058). A new
minimal example, `examples/embryonaut_vendoring_demo` (consuming domain `Gadget`) plus a
vendored package at `examples/embryonaut_vendoring_demo/vendor/embryonaut_bluebooks/widgets`
(`Widget`), proves the vendoring mechanism dispatches and codegens correctly on Rust with
the same rigor `examples/banking` already gives `uses_framework` — real conformance
fixtures, a `spec/project_rust_pipeline_spec.rb` entry, and a `Hecks::Fuzzing::SequenceGenerator`
pass, all green. Found and fixed along the way: the opt-in `HECKS_PARSER=rust
HECKS_CODEGEN=rust` pipeline never resolved `uses_embryonaut_bluebook` at all (only
`uses_framework`); `bin/project_rust`'s own generated-file header hardcoded
`uses_framework` wording regardless of which DSL word actually attached a chapter;
`Hecks::Corpus` had no accounting kind for a vendored package; three separate test boot
helpers (`bin/model_check`, `spec/model_check_spec.rb`, `spec/parser_parity_spec.rb`) built
a registry with no `root:`, which vendoring requires. The known, separate, pre-existing
lineage/mint-era gap (docs/decisions/0030) is unaffected and explicitly out of scope.

**Removed (1.5.0): command facts as loose keyword arguments to
`dispatch`.** Deprecated in 1.3.x, gone here: `dispatch(verb, to:, with:,
saga_correlation:)` takes no `**legacy_args` any more, and neither does
`dispatch_port(domain, aggregate, port, operation, to:, with:, flat:)`.
A loose fact is now refused by Ruby itself, by name — "unknown keywords:
:name, :pizza". Pass the receiver's identity in `to:` and the command's
facts in `with:`. Code holding a bag of DATA rather than written keywords
— corpus JSON, a decoded webhook, the CLI and JSON doors, a reaction with
no `with:` projection — calls `Dispatcher#dispatch_flat(verb, args)` (or
`dispatch_port(..., flat: args)`), which is the wire form and is NOT
going anywhere; it routes exactly as the keyword door did.
`Invocation.from_call`'s own `legacy:` parameter is `flat:` now, the same
rename all the way down through `Routing.payload`, because that is what
it always was once the keyword spelling was gone. With no caller left,
`Hecks::Deprecation`, `bin/codemod_legacy_dispatch_args` and its recorder
go too — the codemod's whole job was draining this one deprecation, and
the next deprecation can lift the helper back out of this commit's
parent.

## [1.4.0] - 2026-09-19

141 commits since v1.3.0. `rust/host` gains the console's own `/api/*`
surface end to end (`/api/me`, `/api/ui-schema`, `/api/schema`,
collection reads and writes, presentation reads) plus the write path
for `PUT /api/presentation`, an unauthenticated JSON request now gets a
`401` instead of a login redirect, and a `deployed_to("AwsLambda")`
domain can name its own stack prefix and function name for a stack that
predates either convention. Loose keyword facts to `dispatch` are
deprecated (I3); the keyword door itself now closes in 1.5.0, not
1.4.0, since this release ships the warning without yet removing what
it warns about. Full detail below.

**Deprecated: command facts as loose keyword arguments to `dispatch`.**
`runtime.dispatch("Banking::Account.Credit", number: { value: "a1" },
amount: { cents: 100 })` still works and now warns once per call site;
pass the facts as `with: { ... }` with the receiver's identity in `to:`
instead. Removal is 1.5.0 (`Hecks::Runtime::Dispatcher::
LEGACY_ARGS_REMOVAL`). One bag holding both the route and the payload is
the shape behind nine past routing bugs, and `Runtime::Invocation` now
reads every call's shape in one place — this closes the door that made
the ambiguity possible. `bin/codemod_legacy_dispatch_args` rewrites
existing callers: it records how each site's facts really split (against
the live registry, not the call's text), then rewrites only the sites
every observation agrees on, reporting the rest by name. The framework's
own doors — `Hecks::Router` and the namespace shortcut, the forms app,
the CLI and JSON doors, `Storehouse`, reaction re-entry, `bin/run`,
corpus replay and the fuzzers — hand their argument bag to the new
`Dispatcher#dispatch_flat(verb, args)` instead, the wire form the corpus
JSON, `cli.rs` and a `with:`-less reaction all carry; it routes exactly
as `dispatch(verb, **args)` always did and is not deprecated. Silence the
warning with `HECKS_SILENCE_DEPRECATIONS=1`.

**`rust/host` answers the console's writes: `POST /api/:coll` and
`POST /api/:coll/:id/:command`.** A create runs the aggregate's one
creating command, with the two things the console does around it that
the domain itself cannot — minting an identity nobody should be asked
to type (`slug` from another submitted field, `sequence` from the
records already there) and checking a precondition a creating command's
own `given` cannot express, because a `given` only reads its own
aggregate. Both are the same config `/api/ui-schema` already tells the
client about, so the picker only offers what the server will accept. A
command against an existing record is matched by the snake_cased name
the ui-schema handed the client, refusing an unknown record before an
unknown command exactly as the Ruby engine does. A refused command
comes back `422 {"error": <refusal class>, "message": ...}` — the
kernel names the same classes Ruby's `DOMAIN_REFUSALS` does, so that
envelope agrees name for name. The one strategy that cannot be ported
says so: `identity: {strategy: port}` delegates to the domain's own
`identity_assignment` adapter, Ruby this host has no runtime for, and
refuses with `501` rather than dispatching without the field.

**`rust/host` answers the console's collection reads: `GET /api/:coll`
and `GET /api/:coll/:id`.** Records come out of the kernel's own
`instances` with the record's id beside its fields, exactly as
`Handle#to_h` builds them; the collection key resolves through the same
`collections.<Name>.key` config `/api/ui-schema` advertises, so a
renamed collection (Engagement's own "pipeline") answers under the name
the client was given and a `404 {"error":"NotFound"}` names the
unknown one. `?query=<name>` runs one of the aggregate's OWN declared
queries through the compiled kernel — a new `dispatch::query`, seeding
from the existing snapshot read and running the kernel's `{"query"}`
step — with its arguments taken from same-named params and shaped the
way each one wires (a reference or primitive bare, a value object
wrapped in its own single field). An unknown query name or a missing
required argument degrades to the plain `.all()` rather than erroring,
which is the Ruby engine's own rule. `?sort=`/`?direction=` honour the
collection's own sortable config and only the shapes an ORDER BY can
actually push down, sorting in memory here (there is no SQL to push
into) with Postgres's own null placement.

**`rust/host` answers the console's `/api/ui-schema` and `/api/schema`.**
`UiSchema.build` ported to Rust, rule for rule: one live domain IR plus
the presentation config in, the same nav / columns / detail fields /
field shapes / lifecycle transitions / create forms document
the client's console has always served out. Verified differentially, not
just by unit test — the Rust document is BYTE-IDENTICAL to the Ruby
engine's for a real client domain, both with its real 8KB
presentation config and with none at all. That diff found the one real
disagreement in the port (Ruby's `String#split` drops trailing empty
segments and Rust's does not, which showed up as `"  State  "` where
Ruby renders `"  State"` in every table header) and it is fixed and
pinned. `/api/schema` — every aggregate's real lifecycle states and
real declared queries, each query argument shaped through the same
`field` a create form's inputs go through — is identical too.

**`rust/host` answers the console's `/api/*` surface: `/api/me` and
`/api/presentation`.** The deployed Rust host already refused an
unauthenticated `/api/...` request exactly the way the Ruby console
engine does; an authenticated one fell through to this host's own
`/<Domain>/<aggregate>` router and came back `404 no domain "api"
loaded`. The refusal contract matched and the success contract didn't.
`/api/me` now answers the same signed-in member hash
(`email`/`name`/`identity_id`/`role`) the console's own
`session[:member]` carries, and `/api/presentation` the same nested
config `PresentationConfig.load` returns — read from the `ConsoleSettings`
chapter's own Postgres head views (`state_style_head`,
`collection_head`, `overview_head`), in the database this host already
holds a connection to, since that chapter is pinned to Ruby's Postgres
adapter deliberately and permanently and is not in this crate's flat
journal. A domain with no such relations reads back an empty config
rather than failing. `PUT /api/presentation` is deliberately NOT ported
and refuses with `501 NotImplemented` naming why: this host has no
`ConsoleSettings` kernel to dispatch that chapter's commands through,
and writing the rows behind its back would skip the invariants those
commands enforce.

**`rust/host`: an unauthenticated JSON request gets a 401, not a
redirect to the login page.** The web gate used to answer every
unauthenticated request the same way — `302` to `/login` — including
ones that asked for JSON, so a `fetch()` or a `curl` followed the
redirect and got `200` and an HTML login page where it expected data.
A JSON-shaped request now gets `401 application/json` with
`{"error":"Unauthenticated","message":"sign in first"}`, the Ruby
console engine's own refusal body, key for key; everything else still
redirects to `/login` exactly as before. JSON-shaped means a path under
`/api/` (the Ruby engine's own rule, which likewise ignores `Accept:`)
or one of this host's own routes asking for any format but `.html` —
read through the same `split_format` the renderers use, so the gate
can't disagree with the response the same path would have produced
with a session. Found in production, where a deployed domain's own CI
assertion that `/api/clients` is `401` had quietly stopped holding once
the Rust host, rather than the Ruby engine, was serving it.

**`deployed_to("AwsLambda") { stack_prefix "..." }`.** An optional
setting for the `hecks-` half of a domain's own stack name (and so both
Lambda function names, the Google OAuth secret, and the bastion stack),
for a domain whose live stack predates the convention — Embryonaut's
`hecksagain-embryonaut`. The counterpart to `owner_stack`, which covers
the same legacy name from a Shared-mode borrower's side. Defaults to
`hecks`; existing recipes regenerate unchanged.

## [1.3.0] - 2026-09-12

**`hecks_qa`, resurrected: a continuous adversarial Ruby/Rust parity
loop.** The `QualityControl` bluebook is back and wired to
`model_check`, running as its own durable ledger (`Bug`/`Patch`/
`Improvement`/`Angle` aggregates, PR discovery via webhook) instead of
a one-off script. `bin/qa_sweep` drives real parallel-OS-process sweeps
across a growing rotation of stress domains (`nested_pieces`,
`waybill`, `ledger_ordering`, `chess`, `tenant_ledger`,
`referral_chain`, `corrections`, `lease_clock`, and more), with
era-boundary/concurrency fuzzing and Memory-vs-Postgres
persistence-adapter parity as first-class sweep modes alongside the
original engine-agreement checks. Across continuous operation since
1.2.0 it found and closed 36 numbered Ruby/Rust divergences
(`BUG#1`–`BUG#36`): entity and saga command routing at nesting depth
≥2, `corrects`/`reverses` and entity-level admissibility, tenant-scoped
queries and `authorize ..., tenant:` enforcement on writes, value-object
and required-argument validation (`from_json` admission order,
null/blank identity, non-string references), `AlreadyExists`/`NotFound`
ordering, fuzzer-generated Integer bounds, and a `PostgresEra`
superuser RLS bypass (`BUG#24`). The full reasoning trail for each
lives in the `QualityControl` ledger itself, not duplicated here.

**Rust kernel: real `actor_id`-backed `RoleAssignment` in
`check_role`.** Closes the governance self-exempt gap the 2026-09-08
review flagged — Rust's role check now does the same lookup Ruby does
instead of trusting an unchecked `actor_id`.

**Ubiquitous Language glossary.** A new glossary projector gives every
domain — `hecks_qa`'s own ledger included — an A-to-Z, non-kind-grouped
reference generated straight from its bluebook.

**CI:** `rspec_postgres_io_parallel` is now a real GitHub Actions
matrix, pre-filtered to files `--tag io` can ever match, grouped by
cached real runtime rather than file count, and skipped entirely when
nothing it covers changed.

## [1.2.0] - 2026-09-09

**`rust/host` closes its silent-wrongness gaps against a real
persistence backend.** It now refuses loudly at boot when a domain
binds an aggregate to a persistence adapter it has no backend for
(previously it dispatched through its own flat Postgres path
regardless of what the domain declared, with lineage/era boot gates
skipping silently since Heki is never lineage-capable). Its
cross-domain delivery loop no longer drops sibling reactions the
instant one delivery exhausts its retries. `PostgresEra`'s advisory
lock (ADR 0036) now covers its whole cross-process dispatch order
instead of only `append`/`atomic_put`, and its lock-key domain default
no longer risks colliding with an unrelated domain when constructed
without an explicit `domain:`.

**`bin/run` no longer crashes on any domain that declares a `port`.**
`CliProjector#port_spec` called a method (`receiver_options`) defined
nowhere in the codebase — `examples/pizzas`' `PaymentGateway` port
included, so `bin/run examples/pizzas` failed with `NoMethodError`
before printing even a help listing. No corpus domain's `.bluebook`
exercised a port, so nothing caught it until now.

**Rust parity fixes from the ongoing Ruby/Rust survey.** Closed-set
(`one_of`) `from_json` admission now matches Ruby's check ordering
instead of requiring the wrapped-string shape before admission is
checked; `corrects` now ports `reverses: true` (increment/decrement)
correctly; policies and process managers now merge across chapters the
same way Ruby does. ADR 0037's remaining "honest addendum" divergences
were re-verified live (not just re-read) — one closed outright, the
rest confirmed already fixed by the generated-dispatch reordering that
shipped for Findings 3-5.

**Reliability and hygiene:** Postgres adapter self-heals a missing
column or a killed connection on boot instead of failing over the
whole domain; two specs that were silently passing without exercising
the behavior they claimed to (`read_model_interpreter_spec`,
`parser_parity_spec`) now actually test it; a new Ubiquitous Language
glossary projector; value-object *lists* now hydrate correctly (ADR
0047 previously only covered single value-object attributes);
`read_model`'s `on:` now names which many-side a nested
`where`/`order_by`/`limit`/`offset` targets; `rspec_rust_io` splits
into 3 parallel CI jobs.

## [1.1.0] - 2026-09-09

**Transactional outbox for domain events and external effects (ADR
0053).** Every reaction a dispatch owes — a policy or process manager's
own trigger, plus any outbound port operation — is now recorded as one
row per (event, consumer) in the SAME adapter transaction as the
aggregate's own save, not announced in-process and hoped for. The
dispatcher drains it inline right after (`pending` → `claimed` →
`delivered`/`failed`); anything still `pending` at the next boot is
redriven automatically, and anything `claimed` is surfaced for a human
rather than silently retried. New adapter contract
(`transaction`/`outbox_enqueue`/`claim`/`settle`/`rows`) on Memory,
Sqlite, Postgres and PostgresEra; Sqlite's own plain `save` is atomic
now as a side effect of making its transactions re-entrant. Adapters
with no outbox implementation (Heki, LocalStorage, D1 today) get a
boot-time warning rather than a silent gap. See ADR 0053 for the full
design and `runtime.outbox.rows`/`redrive!`/`log` for inspecting it
live.

**LocalStorage: a `persisted_by` adapter for browser-hosted domains.**
Mechanically identical to Memory — Ruby has no way to reach a real
browser's `window.localStorage`, so an honest Ruby-side implementation
can only be an in-process stand-in — but it declares real intent:
`persisted_by "LocalStorage"` says a domain expects durable,
single-device, browser-side storage the moment it actually runs where
it's meant to, the same distinction Heki already draws against Memory.
The real browser half lives in `rust/web`'s existing `dispatch(json)`
contract (ADR 0015): an optional `"seed"` (the same `"instances"` shape
`dispatch` answers with) plus `"steps"` lets a host rehydrate from a
prior snapshot and replay only new commands, instead of the whole
history every call — a page bound to this adapter holds that snapshot
in `window.localStorage` itself. `query:` falls back to
`Ports::Query::InMemory` (same trade Heki and Memory both take);
`lineage_capable?` is `false` (no era story — a shape change needs a
hand migration, same as Heki); `tenant_capable?` is trivially `true` (a
browser tab is exactly one origin, one user).

**The Bluebook semantics document's remaining open clauses are all
settled** — the last stretch of a long-running effort to make every
place Ruby and the Rust kernel could quietly disagree either provably
agree or name the gap explicitly (`docs/semantics/bluebook-semantics.md`;
the corpus-owned fixtures under `spec/corpus/semantics/` pin each one
on both runtimes where both apply). The ones most likely to actually
change behavior in an existing domain:

- **Integer is a signed 64-bit integer everywhere (C3.3).** A bare
  argument past ±2^63−1 is now a clean `TypeMismatch` at the boundary,
  and an expression sum or a `then_set` `increment`/`decrement`/
  `multiply` whose result leaves that range is an evaluation `Fault` —
  both runtimes now refuse where Ruby's own arbitrary-precision
  `Integer` used to silently promote to Bignum and keep going. If a
  domain relied on genuinely unbounded integer arithmetic anywhere
  reachable from user input, this is worth checking against.
- **Float is finite (C3.4).** `NaN` and the infinities are refused at
  bare-argument boundaries too, and a non-finite sum is the same
  `Fault` as C3.3's integer overflow.
- **A command's effects are one update set over the PRE-dispatch state
  (C4.2), and appended-entity identities mint highest-plus-one, never
  size-plus-one (C4.5).** Every mutation source — argument, literal, or
  `state(:field)` — reads the record as it was before the command, not
  as an earlier mutation in the same command left it; declaration
  order carries no meaning, and writing the same field twice in one
  command now refuses at build instead of silently last-wins.
- **The Rust kernel now enforces aggregate and entity invariants
  (C6.2).** It previously had no invariant step at all — a deployed
  Rust domain would accept states Ruby refuses. Value-object
  validation itself only ever runs on construction from real input,
  never on a trusted reload from storage (C6.3).
- **A delegated leg's events are emitted with the parent's own commit,
  never before it (C7.2).** Ruby used to emit a delegated entity's
  event the moment that leg succeeded, before the parent's own
  `ensures`/invariants/save — so a parent that went on to refuse had
  already left the leg's event on the log and in the adapter. Rust was
  already correct; Ruby now matches.
- **An evaluation fault is its own outcome, never a refusal (C8.3), and
  every declared command argument is type-checked at the boundary
  regardless of shape (C3.8).** A bare primitive argument of the wrong
  type — not just a malformed value object — is now a clean
  `TypeMismatch` refusal instead of a chance to reach rule evaluation
  and fault there instead.
- **A saga leg is selected by (event, current state), not event name
  alone (C10.3), and reactions for one dispatch's whole batch of
  announced events run after every event in that batch commits, per
  event, policies then sagas (C10.2).** Two legs answering the same
  event from different `from:` states are refused as ambiguous at
  build now, rather than one being permanently unreachable.
- **A `corrects` target is judged against the aggregate's own durable
  event history, not in-memory state (C9.2);** an `ensures` reads the
  settled (post-mutation) state when a name is both an argument and a
  field, the mirror image of how a `given` already reads the
  pre-mutation state (C2.3); and the lifecycle field moves only by a
  declared transition — a bare `sets` on it, or two transitions for
  one command with overlapping `from:` states, now refuses at build
  (C5.3).

All of the above apply to existing domains without any DSL change —
they tighten what was previously either silently wrong on one runtime
or genuinely undefined, not new syntax to opt into.

**Deploy tooling: `bin/project_wasm` now honors the `HECKS_PARSER=rust
HECKS_CODEGEN=rust` opt-in `bin/project_rust` already did.** Previously
it unconditionally shelled out to the Ruby generator regardless of that
env pair, so the `.wasm` a deploy Makefile's `build-<LogicalId>` target
ships to Lambda went through Ruby even when the rest of a toolchain was
built Ruby-free. Opted in, it now delegates to `hecks-build --wasm`
instead of running its own regenerate-then-`cargo build` sequence.

**A `hecks-codegen` crash on a delegating command with a single
mutation is fixed** — found closing an unrelated corpus-coverage gap
(`examples/roster` had never actually been proven byte-identical
between the two Rust generators despite being in CI's own trusted
drift-check corpus). Only reachable through the opt-in all-Rust
pipeline (`HECKS_PARSER=rust HECKS_CODEGEN=rust`); the default Ruby
generator was never affected.

**`IsolatedBoot` tolerates a transient file vanishing mid-copy** — a
real race under the pre-push hook's own parallel test runner, where
another worker's atomic Heki write can drop a `.tmp.<pid>` file between
the directory glob and the copy. Development/CI-only; never affects a
deployed domain.

**A test fixture that embedded a real-looking production database
endpoint and password (for a URI-reserved-character parsing test) now
uses a synthetic value that preserves the same reserved characters.**
No evidence it was ever a live credential; fixed as hygiene regardless.

**Single-element value objects strictly answer `.value`.** A value object
with exactly one declared attribute is a name for a scalar, and the
language now treats that as a rule rather than a convention:

- New bare shorthand: `value_object "Price", Integer` — no block, a type
  in second position — declares exactly one attribute named `value` of
  that type; pure sugar for the block form's single `attribute :value,
  Type` line (byte-identical IR). Type AND block together refuse
  (`Malformed`); bare `value_object "Name"` with neither keeps its
  historical empty-attribute behavior. Grammar rows, the Rust parser
  (`hecks-parse`, byte-exact parity), and reference docs all carry the
  new spelling.
- Runtime alias: every single-attribute value object answers `.value`
  (and `[:value]`/`key?(:value)`/`with(:value, ...)`), aliasing its real
  sole field whatever it is named — `Money{amount}` and `Label{value}`
  read identically. Multi-attribute value objects keep refusing
  `.value`. Serialization is deliberately NOT aliased: `to_h`/`to_json`
  keep the real field name.
- The scalar-unwrap rule is count-gated, not name-gated, everywhere both
  engines read it: `Resolver#unwrap_scalar`, the generated Rust
  `Fielded::as_scalar` (rust/project + rust/codegen, in lockstep), the
  kernel's own `Json::as_scalar`, SQL member-picking
  (`SqlQueryBuilder#query_expression`), and Memory ordering
  (`InMemoryOrdering#sortable_path`) — a bare-field predicate or query
  over `EmailAddress{address}` now means its one field, exactly as it
  always did for a field literally named `value`.
- Call-site collapsing (already count-gated in
  `Coercion#fields_for`) is now documented and pinned as part of the
  language: `price: 10` and `price: { amount: 10 }` build the identical
  single-attribute value object; the explicit spelling keeps working,
  and multi-field shapes still require their fields spelled out.

**The translation audit's preview now reads through the SAME
layered-or-full SQL selection a real mint materializes with.**
`translated_latest` (`bin/translation_audit`'s own preview, and the
real mint-time gate in `coverage_check.rb#audit!`) used to call
`chain_sql` unconditionally; `compile_head!`, at actual mint time,
picks the LAYERED build instead whenever era >= 3 and a prior matview
exists — most eras of any domain that has minted more than a couple of
times. The two were asserted equivalent by spec, but only tested for
an ordinary (non-rekey) edge; a rekey's own `id_column` CASE went
through the layered path at real mint time and through `chain_sql`
alone at every preview, two independently-maintained implementations
with no shared test ever exercising both for the SAME rekey. Pulled
into one `head_body_sql` picker both call, with a defensive
`edges.size != era - 1` guard on the layered path (a caller handed a
shorter edge chain against the same target era — the audit's own
"before" reading always is — used to index past its own array bounds
instead of falling back cleanly). A rekey reaching era 3+ now audits
against the literal SQL a real mint will run, not a second guess at it.

**`.set?`/`.unset?`, a deliberately narrower sibling of `.present?`/
`.blank?`.** `!receiver.nil?`, full stop — an assigned-but-empty
`String`/`Array` is `.set?`, unlike `.present?`'s own Rails-standard
emptiness reading of the identical value. For an optional field whose
only legitimate unset state IS nil, that conflation was a real trap;
these ask the narrower question by name instead. Ported to the Rust
kernel (`Expr::Assignment`, `expression_operators::presence`) alongside
the Ruby resolver; `rust/host`'s JSON interpreter parses it structurally
but does not yet evaluate it, the same boundary `.present?`/`.blank?`
themselves already sit behind there.

**`GivenNotMet#detail`.** A refused `given` whose top-level shape is a
bare comparison now carries its own resolved operands — "left: X,
right: Y" — as `#detail`, off `#message` (every corpus spec asserting
an exact refusal string keeps passing unchanged). Rides on Ruby's own
`#detailed_message` (3.2+), so it shows up in an irb/console
unhandled-exception banner without any caller code reading it on
purpose.

## [1.0.2] - 2026-08-28

**Gem page cleanup, now that the gem is actually published.** `1.0.0`
shipped before `gem install hecks` was live on RubyGems, so the README's
Quickstart still said "There is no published gem" and had no Install
section — the first thing a visitor reads contradicted reality. Fixed:
an `## Install` section now sits right after the intro, and Quickstart
points at `git clone` for the examples/docs rather than implying it's
the only way in. Gemspec also gained `changelog_uri` and
`documentation_uri` metadata, which render as links on the RubyGems page;
`homepage`/`source_code_uri` were already correct (`heckslabs/hecks`,
not the `chrisyoung/hecks` fork/redirect). Metadata is baked into the
published gem version, so this needed its own release rather than
riding along on `1.0.1`.

## [1.0.1] - 2026-08-28

**Cross-tenant boot-isolation gap closed.** `refuse_unless_tenant_capable!`
existed and was directly tested (ADR 0025's gate), but nothing in the boot
path actually called it — a second tenant booting the same directory on a
tenant-incapable adapter went unrefused. Wired into
`ProjectRegister#register` rather than `run_boot_gates!`: boot gates run
per-boot and have no way to see a prior boot, while `ProjectRegister` is the
shared route table where two tenant boots of one directory actually
converge, keyed on `[directory, bluebook.name]`. The first registration of a
directory is never refused, so a plain single-tenant deployment boots
unchanged; a second, incompatible tenant is refused before its routes are
added to the table, so a leaking tenant is never reachable through
`Router#resolve`. `1.0.0` shipped with this gate unwired; anyone who pinned
that version should move to `1.0.1`. See `docs/1.0-readiness.md`'s "Known
gaps at 1.0" section for what's still open (read-model cross-engine
agreement, ADR 0037 findings 3-5).

## [1.0.0] - 2026-08-28

**ADR 0025 lands: the DSL redesign this whole cycle was blocked on.** All 15
slices (S0a/S0b, S1–S13) are done — see `docs/dsl-work-slices.md` for the
full per-slice record. This is the breaking cleanup the 1.0 promise is being
made *about*, not incidental to it:

- `has_many` / `has_one` / `belongs_to` deleted; `reference_to` is the one
  spelling for a reference.
- `identified_by`'s three forms collapsed to one.
- Reference traversal gets its own `/` hop operator, split from `.`'s
  field-walk.
- The attribute type position loses the quoted-string and default-to-`String`
  forms — a bare constant is the only spelling; `one_of:` replaces the
  closed-set wrapper block for the single-field case.
- Events are first-class: `emits`/policy `on`/saga `transition`/`starts_on`/
  `ends_on` all take a bare constant (`Order::Placed`), not a quoted string.
  The full corpus (`examples/`, `lib/hecks/framework/bluebook/`, the
  self-hosted language's own grammar) is migrated — 136 sites moved off the
  quoted spelling; the 2 remaining (`PortOperation#emits` in pizzas'
  `PaymentGateway` port) are a deliberately different, text-kind grammar
  context, not an oversight. The old quoted spelling is still accepted
  everywhere, not refused — refusing it is a separate, undecided design call.
- `projects` gives an aggregate a synchronously-seeded local copy of a
  cross-aggregate field, replacing direct stored-reference dereferencing in
  `given`/`ensures`/`invariant` — an explicit, documented eventual-consistency
  tradeoff (`RebuildSweep` covers out-of-band drift).
- A real corpus use or a named, reasoned exemption for every documented DSL
  word (`spec/word_coverage_spec.rb`), so the reference docs can't silently
  drift from what the language actually does.

`docs/1.0-readiness.md`'s gate is satisfied: ADR 0025 landed with the corpus
migrated and docs regenerated, the property fuzzer's real-adapter mode
covers Postgres/Sqlite, the 8 previously-open GitHub issues and the full
issue-tracker reconciliation (`hecks-hecksagain` epic, `qa-legacy`, misc) are
closed at 0 open, and the M1–M19/L1–L24/Rust-parity divergence list is
re-verified (53 of 55 fixed or no longer applicable; the 2 remaining carry
an honest caveat rather than a false "fixed" — see
`docs/audits/2026-08-28-m1-m19-l1-l24-rust-parity-reverify.md`).

**Update, 2026-08-28, same day:** the Rust runtime projection gap named
below as a known, out-of-scope-for-1.0 limitation was closed the same day,
in the same release — PR #433 seeds `projects` fields at dispatch time in
Rust (`ProjectedFieldSpec`/`seeded_projections`/`SetProjectedField`,
`rust/src/kernel/reference_lookup.rs`), closing every one of the 15
`rust_conformance_spec` failures the gap below describes. `rust_conformance_
spec` is 23/23, zero failures, as of this release.

**Known, out-of-scope-for-1.0 gaps**, tracked separately rather than
silently shipped: a real dangling-reference data-integrity gap found by the
generated-sequence fuzz bridge (ADR 0037 Finding 5); S18 (migrating `raise
Malformed` call sites into the meta-domain — scoped, not started, ADR 0026).

Everything below this line is unchanged content from `[Unreleased]`, carried
forward as this release's own history.

### Fixed

- **The Storehouse MCP bus dispatched role-gated commands unbound.**
  `dispatch` now refuses a command that declares a `role` when no caller
  (`role:`/`actor_id:`) is bound, rather than silently running it
  unchecked — the fail-open half of ADR 0025's `role` work that the
  Governance RBAC lookup itself didn't touch (that step only upgrades
  what a *bound* role is checked against). `domain:`/`under:` on every
  Storehouse tool are now confined to `Hecks::Storehouse::BOOT_ROOT`
  (the project directory by default, `HECKS_STOREHOUSE_ROOT` to widen
  it) — `Hecks.boot` loads real Ruby, and an unconfined caller-supplied
  path was an unmarked way out of the "narrower, checked surface" this
  bus exists to provide. `bin/hecks_mcp_door` now states its stdio-only,
  unauthenticated-identity transport assumption in its own header; the
  README's authorization claim for this bus is corrected to match.
  (2026-08-27)
- **Entity dispatch had no argument gate at all (H1).** Every aggregate
  command and port operation refuses unknown/absent arguments;
  `EntityInterpreter` (an aggregate's own owned pieces — `Account
  .LedgerEntry.Reverse`) silently didn't, on a comment claiming it
  "inherited" a check nothing on its path ever ran. A bogus argument was
  silently accepted; an omitted declared one silently nil'd the field it
  should have set. Fixed, with a correct addressing rule for multi-hop
  entity chains and a pinning spec. (2026-08-27)
- **The property fuzzer only ever ran against the Memory adapter.**
  `bin/fuzz --adapter sqlite|postgres` now runs the full property battery
  against real Sqlite and real Postgres, not just in-memory. Along the
  way, fixed a real bug this surfaced: any Postgres-bound domain with a
  reference-hop query field (`owner/field`) failed to boot at all
  (`PG::UndefinedColumn` in `SchemaBuilder#index_field!`) — previously
  unreachable because nothing had run such a domain against real Postgres
  before. (2026-08-27, PRD 02)
- **`Gemfile.lock` wasn't committed.** The `json` gem was already pinned
  exactly in the `Gemfile`, but every other dependency was free to float
  between CI runs with no diff to review. Committed a lockfile generated
  from a clean `bundle install`. (2026-08-27)
- Era-migration/rekey data-loss findings (H3–H5): deleting an
  era-migrated record no longer resurrects the ancestor era's row in the
  head view; rekey SQL is now folded into the human-approval digest, so
  editing an approved rekey's mapping invalidates the approval; a
  dotted-member `compute` no longer exempts its whole parent attribute
  from the Layer-2 cross-execution equivalence gate. Verified live
  against real Postgres.
- Query engine correctness (H6–H9): `limit`/`offset` ordering across the
  in-memory and reference/entity query engines now matches SQL
  (offset-then-limit, not limit-then-offset); dotted field paths go
  through `FieldPath.dig` everywhere instead of raw hash access; `one_of`
  closed sets are covered by `seal_defaults` (a closed-set attribute with
  a `default:` no longer refuses its own default on create); the
  meta-validator's cache key now incorporates read-model filters, so an
  edited `where`/`order_by`/`limit` can't serve a stale cached filter.
- Routing/deploy correctness (H12–H14): a record id containing `.`
  (e.g. an email-typed identity) now routes correctly instead of 404ing;
  `make deploy` no longer reports failure for a successful Shared-mode
  deploy; `scaffold-translation`/`translation-audit` now refuse by
  default rather than silently scaffolding/auditing the local dev
  database when they'd otherwise miss the intended tunnel.
- Session security (H11): the Rust web layer's session/OAuth-state HMAC
  now refuses to boot on an empty/unset `SESSION_SECRET` instead of
  keying on a publicly-known empty string.
- Systemic query/type-safety root causes (S1–S3): typed query values no
  longer collapse to `.to_s` on the wire; a stored `false` no longer
  reads back as `nil`; identity-value escaping paths reviewed.
- The nested-reaction-dispatch race (`@reaction_depth`) is fixed —
  `Thread.current`-backed, not a shared ivar, safe under a threaded Puma
  deployment.
- 10 real Ruby/Rust parity bugs across the parser, codegen, and kernel,
  including a missing `formerly_known_as` field in the Rust parser that
  broke every `parser_parity`/`codegen_parity`/`rust_conformance`
  fixture that didn't declare it.
- `AppendOnly#record_event`: domain events were never actually persisted.
- A lost-update gap in state-dependent command dispatch.

### Added

- `docs/1.0-readiness.md` — a single, explicit statement of what a `1.0`
  tag will mean, why it isn't tagged yet (blocked on
  [ADR 0025](docs/decisions/0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md),
  a real breaking DSL redesign), and everything else that has to be true
  first.
- `CONTRIBUTING.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/`,
  `.github/PULL_REQUEST_TEMPLATE.md`.
- `chess` as a new example domain.
- The universal MCP dispatch door (`dispatch`/`query`/`state`/`catalog`/
  `describe`/`validate`/`history`/`follow`/`behaviors`), renamed
  `Storehouse`.
- `bin/follow` — a live tail of a domain's append-only journal.
- `corrects` — a retroactive-correction DSL command word.
- Generated Mermaid diagrams (`<Aggregate>_surface.mmd`,
  `<ProcessManager>_saga.mmd`, `frameworks.mmd`) and a README "Diagrams"
  section held to them.
- ADR 0033/0034/0035: eras/lineage extracted behind a registered boot
  gate as a loadable Ruby plugin, with optional Rust lineage.

### Changed

- README rewritten for adoption; the Quickstart-blocking bug it exposed,
  and a license gap, both fixed.
- Removed client-specific deploy artifacts that had been tracked alongside the public example
  domains.

### Docs

- Reconciled `docs/future-features.md`'s "Bug audits" section against
  current `main` — every `H`-numbered audit finding is now marked with
  its real, live-verified status instead of a stale "still open as of
  2026-08-11" blanket claim. See that section for exactly what was and
  wasn't re-verified this pass.
- Fixed a tracking-doc row that wrongly claimed the fuzzer-adapter gap
  was fixed by an unrelated commit (`docs/audits/2026-08-26-issue-tracker-reconciliation-plan.md`) —
  found independently, alongside H1 above, while reconciling docs
  against code in both directions.

[Unreleased]: https://github.com/heckslabs/hecks/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heckslabs/hecks/compare/v0.3.0...v1.0.0
