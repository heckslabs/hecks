# Decisions

<!-- prose anchor="Decisions" purpose="concept" mentions="aggregate:Adr" supports="code_file:lib/hecks/tickets/bluebook/tickets.bluebook code_file:lib/hecks/tickets/bluebook/adapters/decision_files.rb" -->
Each decision record is a file in this directory, `NNNN-<slug>.md` (or `NNNN-<slug>/NN-<slug>.md` for a record
filed under a numbered directory), whose `**Status:**` line says where the decision stands. The files are the
store: `Tickets::Adr` is persisted by the `DecisionFiles` adapter, which reads them at boot, so
`hecks tickets Adr.standing` answers from what is written here. The first word of a status line is read through
the Adr aggregate's `StatusWord` rows; a record names the decisions it supersedes or narrows, and the store
derives the other side. A file the store cannot hold is not listed below. Records whose decision has landed in
code live in `docs/implemented/decisions/`.

## The records

<!-- prose anchor="The records" purpose="concept" mentions="aggregate:Adr" supports="code_file:lib/hecks/doc/regions/decision_index.rb" -->
The table is the store as `DecisionFiles` reads it, by number, written by `hecks language_run.project_reference!`.

<!-- generated:begin id=decisions -->
| decision | title | status | superseded by | narrowed by |
|---|---|---|---|---|
| [0010](0010-ruby-is-the-reference-implementation.md) | Ruby is the reference implementation; other runtimes validate against it, continuously | accepted | 0188 |  |
| [0022](0022-self-host-the-expression-grammar.md) | Self-host the closed expression grammar — close the gap 0009 named and declined | accepted |  |  |
| [0023](0023-rust-parses-and-compiles-bluebooks-directly.md) | Rust parses `.bluebook` source directly, and eventually compiles it with no Ruby involved | accepted |  |  |
| [0025](0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md) | The DSL names one idea one way, and a word earns its place by being used | accepted | 0227 |  |
| [0026](0026-the-language-uses-everything-it-declares-and-what-it-does-not-use-is-a-sub-language.md) | The language uses everything it declares, and what it does not use is a sub-language | accepted |  |  |
| [0029](0029-rust-reads-and-writes-any-era-ruby-mints.md) | Rust reads and writes any era Ruby mints — the lineage runtime, not the lineage authority | accepted | 0030 |  |
| [0030](0030-rust-mints-its-own-eras-at-boot.md) | Rust mints its own eras at boot — no Ruby process in production, no migrations | accepted |  |  |
| [0031](0031-eras-become-a-registered-boot-gate-not-a-hardcoded-loader-step.md) | Eras become a registered boot gate, not a hardcoded loader step | accepted |  |  |
| [0032](0032-delete-eraguards-unwired-file-store-driver.md) | Delete EraGuard's unwired file-store driver; keep the primitives Postgres actually uses | accepted |  |  |
| [0033](0033-eras-become-a-loadable-persistence-plugin.md) | Eras become a loadable persistence plugin, not code core always carries | accepted |  |  |
| [0034](0034-rust-lineage-becomes-optional-in-the-lambda-host.md) | Lineage becomes optional in the Rust Lambda host, but auth stays bound to it | accepted |  |  |
| [0035](0035-optimistic-concurrency-and-per-key-locking-close-the-lost-update-gap.md) | Optimistic concurrency (CAS + retry) and per-key in-process locking close the dispatch-level lost-update gap | accepted |  |  |
| [0036](0036-postgres-era-cross-runtime-concurrency-gap-investigated-not-yet-closed.md) | PostgresEra's cross-runtime concurrency gap — investigated, two real implementation hazards found, not yet safely closeable in one pass | accepted |  |  |
| [0037](0037-generated-sequence-fuzz-bridge-found-real-gaps-two-fixed-three-catalogued.md) | The generated-sequence Rust conformance bridge (PRD 04) — what it found, what shipped, what's catalogued | accepted |  |  |
| [0038](0038-bounded-exhaustive-proof-for-the-expression-sublanguage.md) | A real "proven for all inputs" claim, scoped to the expression sublanguage | accepted |  |  |
| [0039](0039-per-deploy-parity-gate.md) | A per-deploy Ruby/Rust parity gate — and the honest news about banking's own current artifact | accepted |  |  |
| [0040](0040-declared-query-offset-ported-for-real.md) | Phase 10's first shipped capabilities — `offset`, `nulls`, and `authorize`/TenantScope, ported for real | accepted |  |  |
| [0041](0041-phase-10-remaining-backlog-scoped-not-shipped.md) | Phase 10's remaining backlog, scoped by direct investigation — none of it is a same-shape repeat | accepted |  |  |
| [0042](0042-multiply-mutation-op-ported-for-real.md) | Phase 10's sixth shipped capability — `sets :field, multiply: :arg`, ported for real (Integer fields) | accepted |  |  |
| [0043](0043-command-argument-admits-pattern-real-ruby-enforcement-unclear.md) | A real surprise found investigating `list_of admits:/pattern:` — the scalar case's own Ruby enforcement is unclear too | accepted |  |  |
| [0044](0044-cursor-consistency-were-never-a-gap.md) | `cursor`/`consistency` — investigated, and it isn't an equivalence gap at all | accepted |  |  |
| [0045](0045-door-argument-type-bridging-ported-for-real.md) | Cross-aggregate door-argument type-bridging — ported for real | accepted |  |  |
| [0046](0046-clamp-mutation-op-ported-for-real.md) | `clamp` mutation op — ported for real (Integer fields only) | accepted |  |  |
| [0047](0047-remove-mutation-op-is-a-real-ruby-bug-not-a-porting-gap.md) | `remove` mutation op — investigated, found to expose a real, already-live Ruby representation bug | accepted |  |  |
| [0048](0048-corrects-kernel-gap-precisely-scoped-two-real-design-options.md) | `corrects`'s kernel gap, precisely scoped — it's a snapshot-format decision, not just "new kernel architecture" | accepted |  |  |
| [0049](0049-corrects-mutation-op-ported-for-real.md) | `corrects` mutation op — ported for real, including its admissibility check | accepted |  |  |
| [0050](0050-group-by-read-model-support-ported-for-real.md) | `group_by` read-model support — ported for real, for the one real corpus shape | accepted |  |  |
| [0051](0051-list-of-admits-pattern-resolved-by-fixing-a-real-rust-over-enforcement.md) | `list_of admits:/pattern:` resolved — not by porting a new capability, but by removing a real Rust over-enforcement | accepted |  |  |
| [0052](0052-count-median-read-model-aggregation-ported-for-real.md) | `count`/`median` read-model aggregation — ported for real, reusing existing machinery rather than a new two-head-join framework | accepted |  |  |
| [0053](0053-transactional-outbox-for-domain-events-and-effects.md) | A transactional outbox for domain events and external effects | accepted |  |  |
| [0054](0054-keep-one-rust-generator.md) | Keep one Rust generator — decided against; a Ruby-free toolchain is required | accepted | 0054a, 0054b |  |
| [0054a](0054a-make-hecks-codegen-the-only-rust-generator.md) | Make `hecks-codegen` the only Rust generator — 0054 reopened, option 2 adopted | accepted | 0054b, 0086 |  |
| [0054b](0054b-the-ruby-generator-stays-primary.md) | The Ruby generator stays primary — 0054a's direction reversed, its parity fixes kept | accepted | 0086, 0188 |  |
| [0055](0055-read-model-on-target-for-where-order-by-limit-offset.md) | `read_model`'s `where`/`order_by`/`limit`/`offset` can now name WHICH many-side `include` they target | accepted |  |  |
| [0056](0056-ruby-self-correctness-track.md) | A Ruby self-correctness track, separate from Rust parity | accepted |  |  |
| [0057](0057-auto-discover-codegen-drift-regen-domains.md) | `checks_codegen_drift` auto-discovers its own domain list, instead of a maintained one | accepted |  |  |
| [0058](0058-uses-embryonaut-bluebook-proven-rust-conformant.md) | `uses_embryonaut_bluebook` proven Rust-conformant via a minimal vendoring demo domain | accepted |  |  |
| [0059](0059-postgres-era-storage-name-collision-across-domains.md) | PostgresEra's `head_view`/`head_snapshot`/`matview` now domain-qualify, closing a cross-domain storage_name collision | accepted |  |  |
| [0061](0061-query-dsl-aggregation-count-sum-group-by.md) | Query-DSL aggregation (`count` / `sum` / `group_by`) — the gap is narrower than reported, and one part of it is a defect | accepted |  |  |
| [0062](0062-mcp-servers-need-real-authentication-before-any-network-transport.md) | The MCP servers stay stdio-only, and a network transport needs real authentication first | draft | 0103 |  |
| [0063](0063-framework-and-grammar-chapters-and-cargo-features.md) | Should the framework and grammar chapters get Cargo features of their own? | draft |  |  |
| [0064](0064-client-boundary-map.md) | Map: a Hecks with no client material, and a right home for each piece that leaves it | accepted |  |  |
| [0064/01](0064-client-boundary/01-what-counts-as-a-client-name.md) | 01: What counts as a client name, and does "zero" include shipped history? | accepted |  |  |
| [0064/02](0064-client-boundary/02-is-commerce-a-hecks-capability.md) | 02: Is commerce a Hecks capability or a client feature? | accepted | 0094 |  |
| [0064/03](0064-client-boundary/03-client-name-inventory.md) | 03: Client-name inventory | accepted |  |  |
| [0064/04](0064-client-boundary/04-what-the-fargate-projection-emits-today.md) | 04: What the Fargate projection emits today | accepted |  |  |
| [0064/05](0064-client-boundary/05-a-javascript-package-for-hecks-clients.md) | 05: A JavaScript package for Hecks clients | accepted |  |  |
| [0064/06](0064-client-boundary/06-the-npm-scope.md) | 06: The npm scope | accepted |  |  |
| [0064/07](0064-client-boundary/07-rate-limit-defaults.md) | 07: Rate limit defaults | accepted |  |  |
| [0064/08](0064-client-boundary/08-platform-tooling-that-belongs-in-hecks.md) | 08: Platform tooling that belongs in Hecks | accepted | 0094 |  |
| [0064/09](0064-client-boundary/09-the-live-banking-deploy-recipe.md) | 09: The live banking deploy recipe | accepted |  |  |
| [0064/10](0064-client-boundary/10-who-generates-deploy-and-smoke-scripts.md) | 10: Who generates deploy and smoke scripts | accepted |  |  |
| [0064/11](0064-client-boundary/11-how-to-slice-the-client-name-scrub.md) | 11: How to slice the client-name scrub | accepted |  |  |
| [0065](0065-silent-wrong-constructs-are-refused-or-fixed.md) | A construct that silently returns a wrong answer is fixed or refused, and the two known ones are sequenced | accepted |  |  |
| [0066](0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md) | The gem ships a `hecks` executable, and development tooling stays in the repo | accepted |  |  |
| [0067](0067-a-single-attribute-value-object-takes-a-bare-scalar.md) | A single-attribute value object takes a bare scalar, and no new syntax is added for it | accepted |  |  |
| [0068](0068-releases-keep-their-pace-and-state-a-two-tier-promise.md) | Releases keep their pace, and the stability promise is stated as two tiers | accepted |  |  |
| [0069](0069-the-comment-linter-becomes-a-ci-gate-and-bounds-block-length.md) | The comment linter becomes a CI gate, and it bounds block length against a baseline | accepted |  |  |
| [0070](0070-docs-carry-dated-snapshot-banners-and-a-stale-version-guard.md) | Docs that are dated snapshots say so in a banner, an archive holds the ones that should not be read as current, and a scan catches stale versions | accepted |  |  |
| [0071](0071-the-first-external-target-is-a-standalone-rules-service.md) | The first external adoption target is a standalone rules service | accepted |  |  |
| [0072](0072-the-mcp-door-token-waits-for-a-real-need-and-a-tool-allowlist-comes-first.md) | The MCP door's caller token waits for a network door or multi-agent wiring, and a tool allowlist comes first | accepted | 0103 |  |
| [0073](0073-the-newcomer-path-is-a-memory-default-console-and-a-short-readme.md) | The newcomer path is a Memory-default console and a short README | accepted |  |  |
| [0074](0074-contributing-states-how-changes-are-built-reviewed-and-what-ci-proves.md) | CONTRIBUTING states how changes are built and reviewed, and what CI proves | accepted |  |  |
| [0075](0075-comment-sweep-map.md) | Map: Hecks comments that read like a mature framework | draft |  |  |
| [0075/01](0075-comment-sweep/01-the-comment-standard.md) | 01: The comment standard | accepted |  |  |
| [0075/02](0075-comment-sweep/02-the-public-surface-list.md) | 02: The public surface list | draft |  |  |
| [0075/03](0075-comment-sweep/03-proving-a-rust-change-is-comment-only.md) | 03: Proving a Rust change is comment-only | draft |  |  |
| [0075/04](0075-comment-sweep/04-the-sweep-method-and-cost.md) | 04: The sweep method and cost | draft |  |  |
| [0075/05](0075-comment-sweep/05-a-pilot-rewrite-of-a-sample.md) | 05: A pilot rewrite of a sample | draft |  |  |
| [0076](0076-the-network-door-is-a-separate-service-and-principals-live-in-each-domains-governance.md) | The network door is a separate service, and principals live in each domain's Governance | accepted |  |  |
| [0077](0077-the-network-door-speaks-http-and-takes-a-signed-short-lived-token.md) | The network door speaks HTTP, takes a signed short-lived token, and is tested on a real listener | accepted |  |  |
| [0078](0078-read-model-completes-its-reduction-vocabulary-sum-avg-min-max-percentile-any-all.md) | Read model completes its reduction vocabulary — `sum`, `avg`, `min`, `max`, `percentile`, `any`, `all` | accepted |  |  |
| [0079](0079-postgres-and-sqlite-journal-compaction-gated-by-projection-catchup.md) | Postgres and Sqlite journal compaction, gated by how far each bound projection has caught up | draft |  |  |
| [0080](0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md) | Bin scripts become adapters on a Hecks bluebook | draft |  | 0190 |
| [0081](0081-commands-declare-the-outside-facts-they-need-and-a-rule-across-records-gets-an-aggregate-that-owns-it.md) | Commands declare the outside facts they need, and a rule across records gets an aggregate that owns it | accepted |  |  |
| [0082](0082-the-two-translation-chapters-become-one.md) | The two Translation chapters become one | draft |  |  |
| [0083](0083-a-translation-edge-declares-its-own-rollback.md) | A translation edge declares its own rollback | draft |  |  |
| [0084](0084-a-clone-runs-hecks-console-with-no-environment-variable-and-no-database.md) | A clone runs `hecks console` with no environment variable and no database | accepted |  |  |
| [0085](0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md) | `AwsBox` is a deploy kind: one EC2 box and one RDS instance | draft | 0156 |  |
| [0086](0086-hecks-codegen-is-the-only-rust-generator.md) | `hecks-codegen` is the only Rust generator — 0054b's rejection lifted | draft |  |  |
| [0087](0087-hecks-init-writes-the-stub-files-of-a-new-domain.md) | `hecks init` writes the stub files of a new domain | accepted |  |  |
| [0088](0088-an-ai-driven-interview-records-what-an-expert-says-and-drafts-the-first-domain.md) | An AI-driven interview records what an expert says and drafts the first domain | accepted | 0194 |  |
| [0089](0089-the-mcp-door-gets-a-commands-scope-and-stays-booted.md) | The MCP door gets a commands scope and stays booted | draft | 0103 |  |
| [0090](0090-deploy-scripts-become-commands-on-the-deploy-chapter.md) | Deploy and smoke scripts become commands on the Deploy chapter | accepted |  |  |
| [0091](0091-rubocop-defaults-with-deliberate-overrides.md) | RuboCop runs at its defaults, with a short list of deliberate overrides | accepted |  |  |
| [0092](0092-clients-share-one-database-instance-each-in-its-own-database.md) | Clients share one database instance, each in its own database | accepted |  |  |
| [0093](0093-vercel-is-a-deploy-kind-the-host-as-one-function.md) | `Vercel` is a deploy kind: the domain's host as one function | draft |  |  |
| [0094](0094-commerce-and-the-bluebook-registry-move-to-the-platform.md) | Commerce and the bluebook registry maintainer tooling move to the platform | accepted |  |  |
| [0095](0095-the-site-projects-a-content-editor-from-the-domain-chapter.md) | The Site projects a content editor from the domain chapter | draft |  |  |
| [0096](0096-hecks-bluebooks-sit-in-four-modules.md) | Hecks bluebooks sit in four modules | superseded | 0163 |  |
| [0097](0097-lifecycle-states-carry-marks-the-host-reads-from-the-ir.md) | Lifecycle states carry marks, and the host reads them from the IR | accepted |  |  |
| [0098](0098-a-capability-names-a-duration-the-host-reads-from-the-ir.md) | A capability names a duration, and the host reads it from the IR | accepted |  | 0119 |
| [0099](0099-a-capability-names-a-word-and-a-field-the-host-reads-from-the-ir.md) | A capability names a word and a field, and the host keeps only the adapter's own vocabulary | accepted |  | 0119 |
| [0100](0100-policies-ask-and-the-hecksagon-maps-the-port.md) | Policies ask, and the hecksagon maps the port | accepted |  |  |
| [0101](0101-an-ask-in-flight-is-recorded-by-the-runtime-not-modelled.md) | An ask in flight is recorded by the runtime, not modelled in the domain | draft |  |  |
| [0102](0102-consolidate-bin-scripts-into-domain-driven-aggregates.md) | Consolidate 92 bin scripts into domain-driven aggregates and utility classes | draft |  | 0190 |
| [0103](0103-doors-are-driving-adapters.md) | Doors are driving adapters | accepted |  |  |
| [0104](0104-rehearse-an-era-before-minting-it.md) | Rehearse an era before minting it | draft |  |  |
| [0105](0105-a-box-roll-names-its-restore-point-before-it-changes-anything.md) | A box roll names its restore point before it changes anything | accepted |  |  |
| [0106](0106-an-adapter-declares-its-defaults.md) | An adapter declares its defaults | accepted |  |  |
| [0107](0107-a-release-bump-inherits-its-bases-certification.md) | A release bump inherits its base's certification | accepted |  |  |
| [0108](0108-an-awsbox-world-declares-its-cloudfront-edge.md) | An AwsBox world declares its CloudFront edge | draft |  |  |
| [0109](0109-a-live-box-keeps-the-image-it-runs.md) | A live box keeps the image it runs | draft |  |  |
| [0110](0110-a-client-downloads-the-host-hecks-already-built.md) | A client downloads the host hecks already built | draft |  |  |
| [0111](0111-a-thin-movable-platform-sign-in-extension-in-the-host.md) | A thin, movable platform sign-in extension in the host | draft |  |  |
| [0112](0112-a-quoted-member-cell-stays-a-string.md) | A quoted member cell stays a string | draft |  |  |
| [0113](0113-an-awsbox-box-ships-every-container-log-to-cloudwatch.md) | An AwsBox box ships every container log to CloudWatch | draft |  |  |
| [0114](0114-a-change-is-previewed-confirmed-against-its-plan-then-applied.md) | A change is previewed, confirmed against its plan, then applied | draft |  |  |
| [0115](0115-a-route-row-names-an-edge-function-the-generator-attaches.md) | A route row names an edge function, and the site generator emits both the function and its attachment | draft |  |  |
| [0116](0116-the-roles-that-manage-payments-are-a-setting-of-the-host.md) | The roles that manage payments are a setting of the host | draft |  |  |
| [0117](0117-an-attribute-names-its-pattern-with-matches.md) | An attribute names its pattern with `matches:` | draft |  |  |
| [0118](0118-a-translation-is-a-neutral-plan-and-postgres-compiles-it.md) | A translation is a neutral plan, and Postgres is one compiler of it | accepted |  |  |
| [0119](0119-a-package-declares-its-own-capabilities.md) | A package declares its own capabilities | accepted |  |  |
| [0120](0120-a-refusal-has-one-parent-and-a-handle-names-every-verb.md) | A refusal has one parent, and a handle names every verb | accepted |  |  |
| [0121](0121-a-reference-to-a-record-that-ends-needs-a-policy-for-its-holders.md) | A reference to a record that ends needs a policy for its holders | accepted |  |  |
| [0122](0122-a-projection-answers-what-the-loop-answers.md) | A projection answers what the loop answers | accepted |  |  |
| [0123](0123-an-adapter-provides-capabilities-and-a-ledger-says-which-dialects-compile.md) | An adapter provides capabilities, and a ledger says which dialects compile | accepted |  |  |
| [0124](0124-eras-beyond-postgres.md) | Eras beyond Postgres | draft |  |  |
| [0125](0125-a-bulk-run-sends-one-command-to-every-row-of-a-query.md) | A bulk run sends one command to every row of a query | accepted |  |  |
| [0126](0126-a-group-by-reduces-each-group-and-each-reducer-is-a-row.md) | A `group_by` reduces each group, and each reducer is a row | accepted |  |  |
| [0127](0127-reference-to-one-of-is-a-tagged-reference-to-a-closed-union.md) | `reference_to one_of(A, B)` is a tagged reference to a closed union | accepted |  |  |
| [0128](0128-a-command-can-be-validated-as-data.md) | A command can be validated as data | accepted |  |  |
| [0129](0129-a-bulk-run-compiles-to-one-update-when-its-store-provides-set-transform.md) | A bulk run compiles to one UPDATE when its store provides set_transform | accepted |  |  |
| [0130](0130-cursor-pages-a-query-by-its-order-field-and-identity.md) | `cursor` pages a query by its order field and identity | accepted |  |  |
| [0131](0131-a-domain-can-be-written-in-plain-business-sentences.md) | A domain can be written in plain business sentences | accepted |  |  |
| [0132](0132-an-environment-variable-is-a-one-off-override-or-a-secret.md) | An environment variable is a one-off override or a secret | draft |  |  |
| [0133](0133-a-journal-proves-it-was-not-rewritten.md) | A journal proves it was not rewritten | accepted |  |  |
| [0134](0134-a-bluebook-is-all-of-its-files-and-chapter-is-retired.md) | A bluebook is all of its files, and "chapter" is retired | accepted |  |  |
| [0135](0135-a-context-map-is-declared-and-the-wiring-is-checked-against-it.md) | A context map is declared, and the wiring is checked against it | accepted |  | 0207 |
| [0136](0136-hecks-defaults-to-memory-and-a-local-hecksagon-opts-in.md) | Hecks defaults to Memory, and a local hecksagon opts in | accepted |  |  |
| [0137](0137-an-aggregate-is-the-transaction-boundary-and-model-check-reports-what-crosses-it.md) | An aggregate is the transaction boundary, and model_check reports what crosses it | accepted |  |  |
| [0138](0138-a-bulk-run-has-no-all-or-nothing-mode-because-the-aggregate-is-the-transaction.md) | A bulk run has no all-or-nothing mode, because the aggregate is the transaction | accepted |  |  |
| [0139](0139-a-grant-is-a-utc-instant-and-cannot-end-before-it-starts.md) | A grant is a UTC instant, and cannot end before it starts | accepted |  |  |
| [0140](0140-governance-declares-which-grants-are-live.md) | Governance declares which grants are live | accepted |  |  |
| [0141](0141-a-brief-is-handed-to-a-background-session-by-a-command-not-by-hand.md) | A brief is handed to a background session by a command, not by hand | accepted |  |  |
| [0142](0142-shredding-is-a-request-the-key-vault-answers.md) | Shredding is a request the key vault answers | accepted |  |  |
| [0143](0143-compliance-reviews-a-subject-and-names-no-consumer.md) | Compliance reviews a subject, and names no consumer | accepted |  |  |
| [0145](0145-the-hecks-domains-by-value-links-name-things-that-may-not-exist.md) | The hecks domain's by-value links name things that may not exist | accepted |  |  |
| [0146](0146-console-settings-events-are-facts-and-collection-is-four-aggregates.md) | ConsoleSettings events are facts, and Collection is four aggregates | accepted |  |  |
| [0147](0147-a-subjects-key-is-issued-by-the-vaults-answer.md) | A subject's key is issued by the vault's answer | accepted |  |  |
| [0148](0148-dropping-one-argument-drops-one-argument.md) | Dropping one argument drops one argument | accepted |  |  |
| [0149](0149-the-host-core-names-no-driver-and-the-era-store-is-a-port.md) | The host core names no driver, and the era store is a port | accepted |  |  |
| [0150](0150-a-finding-is-acknowledged-on-the-declaration-it-excuses.md) | A finding is acknowledged on the declaration it excuses | accepted |  | 0207 |
| [0151](0151-key-by-value-and-orphaned-reference-are-acknowledged-per-subject.md) | key_by_value and orphaned_reference are acknowledged per subject | accepted |  |  |
| [0152](0152-the-languages-own-names-are-renamed-with-a-declared-edge.md) | The language's own names are renamed with a declared edge, not kept | accepted |  |  |
| [0153](0153-a-policy-reads-the-emitting-records-identity-as-id.md) | A policy reads the emitting record's identity as `:id` | accepted |  |  |
| [0154](0154-hand-written-code-is-a-kernel-an-adapter-or-a-projector.md) | Hand-written code is a kernel, an adapter, or a projector | draft | 0188 | 0190, 0195 |
| [0155](0155-an-attach-is-an-implied-conformist-relationship.md) | An attach is an implied conformist relationship | accepted |  |  |
| [0156](0156-a-box-is-reached-through-its-edge-and-no-third-party-tunnel-runs-on-it.md) | A box is reached through its edge, and no third-party tunnel runs on it | accepted |  |  |
| [0157](0157-an-argument-can-say-it-sets-its-field.md) | An argument can say it sets its field | accepted |  |  |
| [0158](0158-pull-requests-are-opened-and-merged-through-custodian.md) | Pull requests are opened and merged through Custodian | accepted |  |  |
| [0163](0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md) | Hecks is one context in task modules, and a bang is the only sign of a write | draft |  |  |
| [0164](0164-hecks-distills-to-a-core-that-no-satellite-is-needed-to-build.md) | Hecks distills to a core that no satellite is needed to build | draft |  |  |
| [0165](0165-a-bad-release-is-fixed-forward-or-reverted-by-a-named-rule.md) | A bad release is fixed forward or reverted by a named rule | draft |  |  |
| [0166](0166-a-translation-can-split-one-aggregates-fields-into-others.md) | A translation can split one aggregate's fields into others | accepted |  |  |
| [0168](0168-an-era-is-a-stored-projection-minted-once-per-release.md) | An era is a stored projection, minted once per release | draft |  |  |
| [0169](0169-time-reaches-a-saga-as-a-command-an-inbound-clock-dispatches.md) | Time reaches a saga as a command an inbound clock dispatches | accepted |  |  |
| [0170](0170-saga-state-is-as-durable-as-the-aggregates-it-coordinates.md) | Saga state is as durable as the aggregates it coordinates | accepted |  |  |
| [0171](0171-an-adapter-says-whether-it-stays-inside-and-a-behaviors-suite-loads-by-that.md) | An adapter says whether it stays inside, and a behaviors suite loads adapters by that | accepted |  |  |
| [0172](0172-a-bluebooks-classification-keys-the-dependency-checks.md) | A bluebook's classification keys the dependency checks | accepted |  |  |
| [0173](0173-a-use-case-is-a-goal-its-examples-pursue.md) | A use case is a goal its examples pursue | accepted |  |  |
| [0174](0174-a-red-main-stands-a-flag-that-stops-landing-until-ci-is-green.md) | A red main stands a flag that stops landing until CI is green | accepted |  |  |
| [0178](0178-event-delivery-is-one-context-the-outbox-and-the-inbox-share.md) | Event delivery is one context the outbox and the inbox share | draft |  |  |
| [0179](0179-ledger-names-the-seal-chain-only.md) | Ledger names the seal chain only | draft |  |  |
| [0180](0180-a-process-manager-has-one-name-in-the-language-and-the-runtime.md) | A process manager has one name in the language and the runtime | accepted |  |  |
| [0181](0181-main-moves-only-by-promotion-of-a-green-candidate.md) | Main moves only by promotion of a green candidate | superseded | 0187 |  |
| [0182](0182-one-postgres-adapter-picks-its-layout-from-the-hecksagon.md) | One Postgres adapter picks its layout from the hecksagon | draft |  |  |
| [0183](0183-the-persisted-event-records-who-dispatched-it.md) | The persisted event records who dispatched it | draft |  |  |
| [0184](0184-a-clock-is-a-driving-adapter-that-dispatches-a-command-on-a-schedule.md) | A clock is a driving adapter that dispatches a command on a schedule | draft |  |  |
| [0186](0186-a-refusal-is-ok-false-with-an-error-and-no-supported-flag.md) | A refusal is `ok: false` with an error, and has no `supported` flag | accepted |  |  |
| [0187](0187-main-moves-by-pull-request-and-the-candidate-gate-is-retired.md) | Main moves by pull request, and the candidate gate is retired | accepted |  |  |
| [0188](0188-one-kernel-and-ruby-is-the-front-end.md) | One kernel runs bluebooks, and Ruby is the front end | accepted |  |  |
| [0189](0189-the-host-protocol-is-line-framed-json-with-sessions-and-callbacks.md) | The host protocol is line-framed JSON with sessions and callbacks | draft |  |  |
| [0190](0190-tools-dissolve-behind-ports-and-kept-data-is-read-from-the-committed-world.md) | Tools dissolve behind ports, and kept data is read from the committed world | accepted |  | 0195 |
| [0194](0194-interviews-are-the-beginning-of-work.md) | Interviews are the beginning of work | accepted |  | 0218 |
| [0195](0195-the-boards-read-model-is-declared-and-its-pages-are-projected-from-declarations.md) | The board's read model is declared, and its pages are projected from declarations | accepted |  |  |
| [0196](0196-the-host-protocol-gains-a-port-callback-and-one-nested-step.md) | The host protocol gains a read-only port callback | draft |  |  |
| [0197](0197-persistence-through-the-kernel-is-memory-only-now.md) | Persistence through the kernel is Memory only now | draft |  |  |
| [0198](0198-adapters-are-wasm-components-on-wasip2-with-native-store.md) | Adapters are Wasm components on wasip2 with WIT, and the store stays native | draft |  |  |
| [0199](0199-the-corpus-and-independent-properties-judge-the-kernel.md) | The corpus and independent properties judge the kernel, and nothing seeds the corpus from the kernel it judges | draft |  |  |
| [0200](0200-assurance-placement-and-claims.md) | Assurance stays an example for now; a claim is a health reading, never a required check | draft |  |  |
| [0201](0201-a-resident-per-checkout-holds-the-described-domain-and-forks-a-launcher-line.md) | A resident per checkout holds the described domain and forks a launcher line | accepted |  |  |
| [0202](0202-a-write-from-a-worktree-to-a-shared-ledger-runs-in-the-main-checkout.md) | A write from a worktree to a shared ledger runs in the main checkout | accepted |  |  |
| [0203](0203-layer-the-rust-build-kernel-crate-then-domain-crates.md) | Layer the Rust build: a kernel crate, then domain crates | draft |  |  |
| [0204](0204-an-epic-is-an-aggregate-whose-state-comes-from-its-work.md) | An epic is an aggregate whose state comes from its work | accepted |  | 0206 |
| [0205](0205-the-pipeline-is-its-own-project-switchyard-on-a-pinned-hecks.md) | The pipeline is its own project, Switchyard, on a pinned Hecks | draft |  |  |
| [0206](0206-an-epic-completes-only-when-its-outcome-is-measured-as-met.md) | An epic completes only when its outcome is measured as met | accepted |  |  |
| [0207](0207-no-two-contexts-depend-on-each-other-and-a-standing-cycle-is-deprecated.md) | No two contexts depend on each other, and a standing cycle is deprecated | accepted |  |  |
| [0208](0208-a-landings-course-is-its-lifecycle-and-a-train-is-a-convoy.md) | A landing's course is its lifecycle, and a train is a convoy | accepted |  |  |
| [0209](0209-a-span-is-declared-and-one-engine-pairs-what-opens-with-what-closes.md) | A span is declared, and one engine pairs what opens with what closes | accepted |  |  |
| [0210](0210-nothing-squashes-a-merge-commit-keeps-each-landed-commit.md) | Nothing squashes: a merge commit keeps each landed commit | accepted |  |  |
| [0211](0211-the-plan-tile-reads-a-plan-summary-kept-by-events.md) | The plan tile reads a plan summary kept by events | accepted |  |  |
| [0212](0212-a-failed-verification-names-the-first-bad-merge-and-decides-nothing.md) | A failed verification names the first bad merge and decides nothing | accepted |  |  |
| [0213](0213-the-run-ledger-stays-on-sqlite.md) | The run ledger stays on SQLite until locks recur after the purge | accepted |  |  |
| [0214](0214-a-red-main-reverts-its-one-bad-merge-by-policy.md) | A red main reverts its one bad merge by policy | accepted |  |  |
| [0215](0215-the-third-trial-lands-light-and-lets-ci-on-small-trains-be-the-check.md) | The third trial lands light and lets CI on small trains be the check | accepted |  |  |
| [0216](0216-a-role-gated-command-refuses-a-caller-who-states-no-role.md) | A role-gated command refuses a caller who states no role | accepted |  |  |
| [0217](0217-the-orchestrator-guard-refuses-when-role-guard-cannot-answer.md) | The orchestrator guard refuses when Role.guard cannot answer | accepted |  |  |
| [0218](0218-the-product-owner-owns-what-the-planner-owns-how-and-features-land-dark.md) | The product owner owns what, the planner owns how, and features land dark | accepted |  |  |
| [0219](0219-the-scrum-master-diagnoses-blocks-and-recruits-help-and-never-acts.md) | The scrum master diagnoses blocks and recruits help, and never acts | accepted |  |  |
| [0220](0220-a-run-and-a-day-have-a-spend-bound-declared-as-data.md) | A run and a day have a spend bound, declared as data | draft |  |  |
| [0221](0221-releases-are-cut-by-policy-after-a-soak-and-the-changes-choose-the-version.md) | Releases are cut by policy after a soak, and the changes choose the version | accepted |  |  |
| [0222](0222-signalbox-runs-on-five-laws.md) | Signalbox runs on five laws | draft |  |  |
| [0223](0223-names-are-plain-words-rail-machinery-and-characters-under-hecks-on-rails.md) | Names are plain words, rail machinery and characters, under Hecks on Rails | draft |  |  |
| [0224](0224-an-expedited-work-item-starts-outside-the-cap.md) | An expedited work item starts outside the cap, one at a time | accepted |  |  |
| [0225](0225-an-interview-is-recorded-from-a-speaker-labelled-transcript.md) | An interview is recorded from a speaker-labelled transcript | draft |  |  |
| [0227](0227-identity-is-a-value-concept-and-relationships-state-cardinality.md) | Identity is a value concept and relationships state their cardinality | accepted |  |  |
| [0228](0228-vendored-lineage-scoping.md) | Closing the vendored-lineage gap named in 0030 — scoping, not executed | draft |  |  |
| [0230](0230-option-2-scoping.md) | Option 2 scoping — making `hecks-codegen` the sole Rust generator | draft |  |  |
| [0231](0231-hydrate-entity-list-widened-to-value-object-lists-adr-0047-root-cause-fixed.md) | `Value::Coercion#hydrate_entity_list` widened to value-object lists — ADR 0047's root cause fixed; `remove:`'s own Rust port still deliberately not attempted | accepted |  |  |
| [0232](0232-postgres-era-vendored-bluebook-source-text.md) | PostgresEra's era-1 self-mint now finds a vendored bluebook's own real source text | accepted |  |  |
<!-- generated:end -->
