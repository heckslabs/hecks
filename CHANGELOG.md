# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Dates are when a change landed on `main`, not when this file was written.
Entries below are grouped by theme, not itemized commit-by-commit; see
`git log` for the full history.

## [Unreleased]

**`AwsBox` rolls the box faster and writes executable scripts.** `deploy-box.sh` no longer sleeps a fixed 20 seconds after starting the containers: it waits until every container has been up at least 5 seconds, and still catches one that restarts or exits right after starting. On the live Lifeadelics box that cut the roll from about 40 seconds to 16. The generated `.sh` files are also written with the executable bit, so a caller can run `./deploy-box.sh` directly. ([ADR 0085](docs/decisions/0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md))

**`@hecks/client` can send `actorId`.** `ClientOptions.actorId` (a default for every command), `Command.actorId` and a fifth `dispatch(verb, args, to, role, actorId)` argument send the body's `actor_id`, the Governance identity id of an identified caller. Leave `role` unset and Governance's role assignments decide; the host honors `actor_id` only on its internal protocol. The key is omitted when unset, so existing calls are unchanged.

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
way. Asks without a profile behave as before.

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

**The `Agent` adapter can run an agent under a profile.** `Agent#ask(profile: AgentProfile.new(...))`
names the tools the agent holds, the directories it may write, whether it may reach the network
(`none`, `https` or `any`), the environment variables it sees, a timeout and a spending cap. On macOS
the run goes under the sandbox with that policy, reads of credentials are refused, and the agent
starts with only the environment it was given; where there is no sandbox, a confined run refuses to
start. Without a profile an ask behaves as before. `https` is written but not exercised by the specs.
A profile can instead confine by `claude`'s own permission rules (`confinement: :permissions`): the
agent holds the writing tools only for the directories named, runs with no MCP servers, and keeps
the user's own `claude` login, which the sandbox cannot (it refuses the keychain). `hecks
quality_control mine_combinations --confine` uses it, so the miner's agent writes only its
candidates directory, with a twenty-minute timeout and a two-dollar cap.

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
