# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Dates are when a change landed on `main`, not when this file was written.
Entries below are grouped by theme, not itemized commit-by-commit; see
`git log` for the full history.

## [Unreleased]

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
`hecks_session`, not `lifeadelics_session`. A host that sets nothing logs its
existing sessions out on upgrade; set `HECKS_SESSION_COOKIE=lifeadelics_session`
to keep them.

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
`environments/production.world`. Removed: `deploy/lifeadelics/`, the committed
`rust/src/generated/{embryonaut,lifeadelics,membership,newsletter,privacy}/`
snapshots, the `embryonaut` and `lifeadelics` Cargo features, and the corpus
machinery that only accounted for external domains (`Corpus`'s `:external`
check kind and vendored-chapter helpers). A client's own build regenerates its
Rust with `bin/project_wasm`, which does not need them. `web/lifeadelics.rs` is
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
(`lifeadelics_session` cookie). Email goes through Resend (`resend.rs`) with
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
`web/lifeadelics.rs`, with no behavior change.

## [2.0.0] - 2026-09-22

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
embryonaut_console has always served out. Verified differentially, not
just by unit test — the Rust document is BYTE-IDENTICAL to the Ruby
engine's for the real Embryonaut domain, both with its real 8KB
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
(`email`/`name`/`identity_id`/`role`) embryonaut_console's own
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
- Removed client-specific deploy artifacts (`embryonaut`,
  `lifeadelics*`) that had been tracked alongside the public example
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
