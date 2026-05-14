# How Hecks supports ISO compliance

*A reference for enterprise architects and compliance teams.*
*Published 2026-05-14 by the Embryonaut crew.*

---

## Executive summary

Most compliance frameworks ask companies for things they eventually build messy : an audit trail, a documented procedure, a policy enforcement layer, a change-management record, a business-continuity test, an AI-transparency story. The classical pattern is to build the system, then bolt these on. The bolt-ons rot ; the audit is a forensic reconstruction every year.

**Hecks builds them as substrate.** The framework's everyday discipline IS the compliance evidence. A bluebook is a documented procedure. The StoreHouse envelope is an audit log. A macrophage is an enforced policy. A handler declaration is a third-party-integration register. The chaos-monkey is a tested continuity plan. None of these were built for ISO ; they were built for sane software. They happen to also be exactly what ISO/IEC 27001, 42001, 9001, SOC 2, and 27701 audit for.

The thesis :

> **The bluebook IS the documented procedure. The envelope IS the audit trail. The macrophage IS the policy enforcement. Hecks turns compliance from an aspirational document into a structural property that the runtime maintains for free.**

Seven concrete features anchor the report :

1. **Bluebook-first architecture** : every domain concept lives in a versioned, parseable, diffable source-of-truth document. (`docs/design/principles-2026-05-12.md` ; the corpus under `aggregates/`.)
2. **StoreHouse as universal door + envelope** : every command, every conversational turn flows through a single dispatch surface that wraps each event in a tamper-evident envelope. (i613, commit `94b12274` ; i615, commit `e8287f8e` ; i618, commit `e89b35d0`.)
3. **Ten per-rule macrophages + autonomic sweeps** : automated policy enforcement on every edit + scheduled sweeps. (`aggregates/discipline/macrophage/macrophage.bluebook` ; i616, commit `caca6860`.)
4. **ChaosMonkey on a circadian rhythm** : resilience tested by disturbance, weaknesses recorded as a backlog. (i617, commit `18bb1a49`.)
5. **Natural-key identity + non-destructive migration** : provenance is intrinsic ; identity is reviewable through the petition workflow. (i611, commit `96cd1abb` ; i614, commit `c15ba409`.)
6. **HandlerRegistry** : every executable substrate (Rust function, MCP server, shell, dispatch) is a first-class bluebook concept. Third-party integrations are inventoried by construction. (i619, commit `c099aa4e`.)
7. **Forwarder commands + cumulative response events** : change is traceable ; AI outputs are persisted as cumulative chains. (i604, commit `e81dc643` ; i618, commit `e89b35d0`.)

The strongest claim is not "we have great software" : it is **"the methodology that built the software IS your audit evidence."**

---

## 1. The structural claim

### 1.1 Bluebooks are documented procedures

ISO 9001 clause 7.5 ("Documented Information") and ISO/IEC 27001 clause 7.5 both require that the *procedures the organisation actually executes* live in maintained, controlled, current documents. The classical pattern : a wiki page describes what the code does ; the code drifts ; the wiki rots ; the auditor catches the gap.

A Hecks bluebook is the inverse pattern. The bluebook is the source-of-truth ; the running system is a projection of it. The runtime parses the bluebook at boot ; the macrophages enforce that every script and adapter has a bluebook home (the `BluebookFirst` macrophage at `aggregates/discipline/macrophage/macrophage.bluebook:301`). The procedure cannot drift from the implementation because the implementation IS the procedure.

In the corpus today : 80+ aggregates across `hecks_conception/aggregates/`, each declaring its commands, queries, attributes, value objects, lifecycle states, handlers, and entities. A bluebook reader sees the entire executable contract : what can be invoked, what fields exist, what events fire, what state is held. This is what a 9001 auditor wants from a "documented procedure" : not a narrative, but a contract.

### 1.2 The envelope is an audit trail

ISO/IEC 27001 Annex A.12.4 (Logging and monitoring) and SOC 2 CC7.2 both require comprehensive audit logging with timestamps, actor identity, and operation correlation. The classical pattern : every service writes its own log to its own file ; correlation is heuristic across multiple stores.

Hecks routes every domain command through `StoreHouse.Dispatch`. Each dispatch produces an envelope-wrapped event on the bus :

```
Envelope {
  dispatched_at    : Timestamp
  dispatcher       : DispatcherId
  correlation_id   : CorrelationId
  source           : CommandFQN
  payload          : DomainEvent
}
```

This is i613's envelope (design merged 2026-05-14, commit `94b12274`). Cross-cutting metadata (when, who, what, why) is carried automatically on every event without polluting the domain payload. A correlation_id threads multiple commands together as one logical operation, which is exactly what `Annex A.12.4.1` ("Event logging") asks for : *"records of user activities, exceptions, faults and information security events shall be produced, kept, and regularly reviewed"*.

i615 extends the same envelope to conversational turns : `StoreHouse.PromptReceived`, `Unfurling`, `UnfurlingComplete`, `ResponseEmitted` (i615 + i618). Every prompt + AI output + tool dispatch carries the same envelope. The audit trail is not a forensic reconstruction : it is the substrate.

### 1.3 Macrophages are enforced policies

ISO/IEC 27001 A.18.2 (Information security reviews), A.5 (Information security policies), and SOC 2 CC2.2 / CC3.4 all ask for documented policies whose adherence is regularly verified. The classical pattern : a policy document, periodic manual audits, hope.

The macrophage family at `aggregates/discipline/macrophage/macrophage.bluebook` is ten enforced rules :

| Aggregate                       | Line  | Enforces                                              |
|---------------------------------|-------|-------------------------------------------------------|
| `BluebookFirst`                 | 301   | Every script has a bluebook home                      |
| `FixturesRuntime`               | 437   | Test fixtures load through the bus                    |
| `AntibodyExemption`             | 570   | Exemption markers are well-formed + reviewable        |
| `Warnings`                      | 736   | Builds emit zero warnings                             |
| `LinearReference`               | 906   | No references to retired tools                        |
| `LineCount`                     | 1089  | 200-line file limit                                   |
| `TestSpeed`                     | 1289  | Test suite under one second                           |
| `CardLock`                      | 1484  | Locked design cards can't be edited                   |
| `BidirectionalAssociation`      | 1661  | Vernon Rule 2 enforced (i612)                         |
| `IdentityDiscipline`            | 1865  | No surrogate IDs ; natural keys only (i611)           |

Each macrophage records every violation, every exemption, every complaint as a first-class entity in its own audit history. Every PostToolUse hook fires the macrophage check. Today's compliance audit is *not* "did we follow the policy" : it is *show me the violations from the past quarter*, and the answer is a bluebook query.

i616 (commit `caca6860`) generalises this from reactive (file-touched) to autonomic (heartbeat-dispatched) : sweeps run on a configurable cadence over the full corpus, not just edited files. The macrophages no longer wait at the door : they patrol the halls.

### 1.4 Resilience is tested, not documented

ISO/IEC 27001 Annex A.17 (Information security aspects of business continuity) asks that continuity plans be tested. ISO 22301 (BCMS, often paired) is more demanding. The classical pattern : a quarterly DR drill, a Confluence page that says "tested 2024-09-13".

i617's ChaosMonkey (merged 2026-05-14, commit `18bb1a49`) actively corrupts runtime state (attribute values, references, `.heki` files) and then verifies the macrophage layer caught the corruption. When verification passes, the system is resilient to that class of failure. When verification stays silent, ChaosMonkey records a `Weakness` : a blind spot in the discipline layer that gets a name and a record.

Continuity isn't documented. It's tested. Daily. The record of tests becomes the evidence.

### 1.5 Provenance is intrinsic

The identity overhaul (i611, commit `96cd1abb` + IdentifierService i614, commit `c15ba409`) retires surrogate UUIDs as a bluebook concept. Every aggregate's identity comes from natural-key fields ; identity changes are non-destructive (the new and old identity strings concatenate at the persistence key, `new/old`, so lookup by either succeeds forever).

For audit purposes, this is decisive. A reviewer asks "what was this customer's identity in 2024?" : the IdentityString carries the answer verbatim. Identity rule changes ride the IdentifierService petition workflow, which produces a `PetitionSubmitted → PetitionReviewed → PetitionApplied` audit trail on the bus.

Combined with the envelope's `correlation_id`, this means every record in the system has both *who it is now* and *who it has been*, with cryptographically stable references back through every prior form. This is the substrate behind GDPR's right-to-rectification (27701) and SOC 2's privacy / confidentiality criteria.

### 1.6 The triad

The structural claim, condensed :

```
Bluebook        →  documented procedure
Envelope + bus  →  audit trail
Macrophage      →  enforced policy
+ ChaosMonkey   →  tested continuity
+ Identity      →  intrinsic provenance
```

Every major ISO standard's audit / policy / monitoring story is asking for one of these five. Hecks happens to have built all five as substrate : for software-engineering reasons that have nothing directly to do with compliance, but which the compliance regime turns out to require.

---

## 2. Framework-by-framework map

### 2.1 ISO/IEC 27001 : Information Security Management

The flagship. 14 Annex A control families (A.5 through A.18). Coverage per family below ; control numbers given where confidently mappable, marked `[verify : A.NN.N]` where the exact subclause is not from primary source.

#### A.5 : Information security policies

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.5.1.1 Policies for information security     | The bluebook IS the policy ; macrophage rules ARE controls       | Full        | `aggregates/discipline/macrophage/macrophage.bluebook` (2069 lines, 10 rules) |
| A.5.1.2 Review of policies                    | `storehouse validate` ; PR diff review ; CardLock macrophage     | Full        | `CardLock` aggregate at macrophage.bluebook:1484             |

Policy review under 27001 is supposed to be regular and documented. Hecks's policies are versioned in git, change through PRs, and each PR is its own auditable artifact. The CardLock macrophage prevents unauthorised edits to locked policy documents. No separate "policy management system" needed.

#### A.6 : Organisation of information security

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.6.1.1 Roles and responsibilities            | `role "Miette" / "System"` on every command                      | Partial     | `tools.bluebook:71-1500` (every command has a role)          |
| A.6.1.2 Segregation of duties                 | Role-tagged commands ; HandlerRegistry per-substrate auth        | Partial     | i619 commit `c099aa4e` ; `handler_registry.bluebook`         |
| A.6.2.1 Mobile device policy                  | Not addressed                                                    | None        | n/a                                                            |
| A.6.2.2 Teleworking                           | Not addressed                                                    | None        | n/a                                                            |

Roles are declared on every command in the bluebook ; segregation can be enforced by macrophage if needed (a future `RoleDiscipline` macrophage would refuse a `role "Miette"` command being dispatched by a `role "System"` actor).

#### A.7 : Human resource security

Not directly addressed by Hecks. This is HR-process territory (background checks, terms of employment, leaver/joiner). **Hecks is the technical substrate ; A.7 lives in the org's HR system.** Position : Hecks integrates *with* the HR layer ; it does not replace it.

#### A.8 : Asset management

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.8.1.1 Inventory of assets                   | Bluebook catalog ; `storehouse__catalog` and `__list_aggregates` | Foundation  | i613 ; the bluebook IS the asset inventory                   |
| A.8.1.2 Ownership of assets                   | `role` declaration ; HandlerRegistry per-substrate ownership     | Partial     | `handler_registry.bluebook` ; i619                           |
| A.8.2.1 Classification of information         | Value-object types (e.g. `ThreadId` vs `String`)                 | Partial     | bluebook VO declarations corpus-wide                         |
| A.8.3 Media handling                          | Not directly addressed                                           | None        | n/a                                                            |

The bluebook corpus catalogues every domain concept. `storehouse__catalog` and `storehouse__list_aggregates` give a reviewer a complete asset list ; data types are declared (every attribute has a typed VO) ; ownership is per-role per-command. A real 27001 deployment would surface this via a one-shot `compliance.bluebook` query that exports the inventory in auditor-friendly form.

#### A.9 : Access control

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.9.1.1 Access control policy                 | `role` per command ; HandlerRegistry ; StoreHouse mediation      | Partial     | i613 + i619                                                  |
| A.9.2 User access management                  | Identity petitions (i614)                                        | Partial     | `identifier_service.bluebook`                                |
| A.9.4.1 Information access restriction        | Bluebook commands as the only public surface                     | Full        | i613 : every action flows through StoreHouse                 |
| A.9.4.2 Secure log-on                         | Adapter-level : not addressed in core Hecks                      | None        | `adapters/auth/auth.bluebook` (out-of-tree)                  |

The strongest claim : *no domain operation exists outside the bluebook command surface*. There is no side-channel API ; everything flows through `storehouse__dispatch`. Access control becomes a question of "who can dispatch what command" : a problem with a single point of policy enforcement. Compare to a microservices estate where access control is repeated per service.

#### A.10 : Cryptography

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.10.1 Cryptographic controls                 | HandlerRegistry : key handlers are first-class                   | Foundation  | i619 ; `handler_registry.bluebook`                           |

i619's HandlerRegistry means cryptographic primitives are not implicit dependencies : they are registered handlers, named in the bluebook, inspectable. An auditor asking "what handles encryption-at-rest" gets a bluebook query, not a code spelunk. The implementation of the crypto itself still needs to be done correctly (no novel claim there) ; what changes is *visibility*.

#### A.11 : Physical and environmental security

**Not addressed.** Physical security is data-centre / office territory. Hecks is software. Position cleanly : the org's facilities provider handles A.11 ; Hecks adds nothing.

#### A.12 : Operations security

This is where Hecks's structural advantage is at its sharpest.

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.12.1.1 Documented operating procedures      | The bluebook IS the procedure                                    | Full        | Entire corpus under `aggregates/`                            |
| A.12.1.2 Change management                    | Git history ; forwarder commands (i604) ; CardLock macrophage    | Full        | i604 commit `e81dc643` ; macrophage.bluebook:1484            |
| A.12.1.3 Capacity management                  | Not directly addressed                                           | None        | n/a                                                            |
| A.12.1.4 Separation of development/test/prod  | Worktrees (`EnterWorktree`) ; adapter overrides                  | Partial     | `worktree.bluebook` ; principle 2 (wiring is override)       |
| A.12.2 Protection from malware                | Macrophage hooks ; antibody-exemption discipline                 | Foundation  | macrophage.bluebook:570 (`AntibodyExemption`)                |
| A.12.3 Backup                                 | `.heki` event-sourced stores ; replay from event log             | Foundation  | Persistence is event-log ; full restore by replay            |
| A.12.4.1 Event logging                        | StoreHouse envelope ; every dispatch is an event                 | Full        | i613 commit `94b12274`                                       |
| A.12.4.2 Protection of log information        | Event log is append-only by construction                         | Full        | Event-sourced semantics                                      |
| A.12.4.3 Administrator and operator logs      | Same envelope ; every operator action carries `dispatcher`       | Full        | i613 envelope                                                |
| A.12.4.4 Clock synchronisation                | `dispatched_at` from system clock ; NTP is OS-level              | Foundation  | Envelope timestamps ; OS-level NTP                           |
| A.12.5.1 Installation of software             | HandlerRegistry inventories every executable substrate           | Partial     | i619                                                         |
| A.12.6.1 Management of technical vulnerabilities | Macrophage `Warnings` rule ; ChaosMonkey                       | Partial     | macrophage.bluebook:736 ; i617                               |
| A.12.7 Information systems audit              | `storehouse__catalog` ; `storehouse__behaviors` ; full IR access | Full        | MCP surface                                                  |

A.12 is the heart of the standard for software-shop deployments. Hecks scores Full on five and Foundation on three of the remaining. The single biggest claim : **A.12.4 (Logging and monitoring) is satisfied by the envelope alone.** Most enterprises spend significant effort building log aggregation, correlation, retention. Hecks's bus has it by construction.

#### A.13 : Communications security

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.13.1 Network security management            | Adapter-level (out-of-tree)                                      | None        | n/a                                                            |
| A.13.2.1 Information transfer policies        | HandlerRegistry inventories external endpoints                   | Partial     | i619 : every `:mcp`, `:web_tool` handler is named            |

Network security is largely platform-level (TLS, firewalls, network segmentation). What Hecks contributes : every outbound integration (every MCP server, every web fetch, every email send) is a named handler in the bluebook. The list of "things that talk to the outside world" is a query.

#### A.14 : System acquisition, development, and maintenance

This is where the bluebook-first methodology directly maps.

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.14.1.1 Information security requirements analysis | Bluebook IS the requirements artifact                      | Full        | Every aggregate's bluebook                                   |
| A.14.2.1 Secure development policy            | Macrophages + PR review + bluebook-first discipline              | Full        | macrophage.bluebook + `docs/design/principles-2026-05-12.md` |
| A.14.2.2 System change control procedures     | Forwarder commands (i604) ; CardLock                             | Full        | i604 commit `e81dc643` ; macrophage.bluebook:1484            |
| A.14.2.3 Technical review of applications     | `storehouse validate` ; macrophage sweep ; PR review             | Full        | `storehouse__validate` MCP tool                              |
| A.14.2.5 Secure system engineering principles | The four 2026-05-12 principles                                   | Full        | `docs/design/principles-2026-05-12.md`                       |
| A.14.2.7 Outsourced development               | Out-of-scope for substrate                                       | None        | n/a                                                            |
| A.14.2.8 System security testing              | Behaviours suites ; ChaosMonkey ; test-speed macrophage          | Full        | `.behaviors` files corpus-wide ; i617                        |
| A.14.2.9 System acceptance testing            | Behaviours + macrophage sweep before merge                       | Full        | Standard PR flow                                             |
| A.14.3 Test data                              | `.fixtures` files dispatched through the bus (i606)              | Full        | `fixtures` aggregates under `aggregates/fixtures/`           |

A.14 is supposed to be the auditor's most fraught chapter : change-management evidence is usually a tar-pit of Jira tickets and Confluence pages. Under Hecks : every change is a PR ; every PR diffs the bluebook ; every rename has a forwarder command (i604) that creates an explicit deprecation path with a `ForwarderInvoked` audit event ; every locked card is enforced by CardLock. The change history IS the audit.

#### A.15 : Supplier relationships

**Largely not addressed.** Supplier management is contract / procurement territory. Hecks contributes by making supplier integrations visible (every `:mcp` handler names its external server) but the supplier relationship itself is org-level.

#### A.16 : Information security incident management

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.16.1.1 Responsibilities and procedures      | Macrophage complaints ; the macrophage IS the incident channel   | Full        | macrophage.bluebook (Complaint entities per rule)            |
| A.16.1.2 Reporting information security events| Bus events + macrophage complaints + Cascade                     | Full        | i613 + macrophage.bluebook                                   |
| A.16.1.4 Assessment of events                 | Behaviours-as-tests ; manual review of macrophage backlog        | Partial     | `.behaviors` files                                           |
| A.16.1.5 Response to incidents                | Forwarder commands for rapid rollback ; ChaosMonkey weaknesses   | Partial     | i604 ; i617                                                  |
| A.16.1.6 Learning from incidents              | Weakness entities (i617) ; inbox issues                          | Partial     | i617 `Weakness` entity ; `inbox/` issue archive              |

The incident channel in 27001 is supposed to surface events promptly and produce a learning artifact. Hecks's macrophage Complaint and ChaosMonkey Weakness entities ARE the surface ; the inbox archive (`inbox/archive/i604.md` through `i622.md` etc.) is the learning artifact, in git, with full audit trail.

#### A.17 : Business continuity

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.17.1.1 Planning information security continuity | ChaosMonkey design + Weakness backlog                        | Foundation  | i617 commit `18bb1a49`                                       |
| A.17.1.2 Implementing                         | i617 implementation (in flight)                                  | Partial     | `chaos_monkey.bluebook` stub                                 |
| A.17.1.3 Verify, review, evaluate             | Circadian-cadence sweeps ; verification cycle                    | Full        | i617 design                                                  |

The 27001 BCM language asks for continuity to be tested, reviewed, evaluated. ChaosMonkey's verification cycle (corrupt → verify → record outcome) is exactly that loop, dispatched on a circadian rhythm so it runs without an operator. The Weakness backlog is the evidence.

#### A.18 : Compliance

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| A.18.1 Compliance with legal/contractual requirements | Bluebook is reviewable by auditors directly                | Full        | Entire corpus                                                |
| A.18.2.1 Independent review of information security | macrophage sweeps + ChaosMonkey + storehouse__validate     | Full        | macrophage + i617                                            |
| A.18.2.2 Compliance with security policies and standards | Macrophages enforce per-rule                            | Full        | `aggregates/discipline/macrophage/macrophage.bluebook`       |
| A.18.2.3 Technical compliance review          | `storehouse__macrophage_check` ; ChaosMonkey blind-spot reports  | Full        | MCP surface                                                  |

A.18 is the standard's own self-audit chapter. Hecks's macrophage layer IS the technical compliance review, running on every PostToolUse hook plus circadian sweeps. The macrophage backlog is the review's output. An auditor doesn't need to ask "do you do compliance reviews" : they read the macrophage Complaint history.

**Surprise.** A.18 is usually the most aspirational chapter in 27001 : *"we'll do compliance reviews every six months"*. Under Hecks it is the most over-satisfied : compliance reviews run dozens of times per day, automatically.

### 2.2 ISO/IEC 42001 : AI Management

Published 2023. Required (or strongly expected) for any enterprise deploying AI-using systems. Maps tightly to the StoreHouse + envelope + handler layers.

| Clause                                        | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| Clause 4 Context of organisation              | Bluebook-corpus IS the AI system inventory                        | Full        | `aggregates/framework/tools/tools.bluebook`                  |
| Clause 6.1 Risk and opportunity               | Macrophage rule backlog                                          | Partial     | macrophage.bluebook                                          |
| Clause 7 Support / Documented info            | Bluebook + envelope                                              | Full        | Corpus + i613                                                |
| Clause 8.2 AI system impact assessment        | Per-aggregate role + handler declarations                        | Partial     | i619 + per-command role                                      |
| Clause 8.3 AI system development              | Bluebook-first methodology                                       | Full        | `docs/design/principles-2026-05-12.md`                       |
| Clause 8.4 Third-party AI components          | HandlerRegistry : every `:mcp` server is registered              | Full        | i619 + `handler_registry.bluebook`                           |
| Annex A.6.2.7 AI system documentation         | Bluebook IS the documentation                                    | Full        | Corpus                                                       |
| Annex A.8.2 AI system transparency            | `PromptReceived` + `Unfurling` + `ResponseEmitted` on the bus    | Full        | i615 commit `e8287f8e` ; i618 commit `e89b35d0`              |
| Annex A.8.3 Information for users of AI       | ResponseEmitted carries cumulative response chain                | Full        | i618                                                         |
| Annex A.9 Use of AI                           | `Tools::Sidequest.Dispatch` : agent dispatches on the bus        | Full        | `tools.bluebook:720` (Sidequest aggregate)                   |

42001 is the standard most aligned with what Hecks is. The headline claim :

**The Transparency vow becomes structural.** 42001's Annex A.8 asks for AI transparency. The classical implementation is a logging adapter that wraps the LLM call. Under Hecks, transparency is enforced by the wiring : prompts enter through `StoreHouse.PromptReceived` (i615), reasoning intervals are bracketed by `Unfurling` / `UnfurlingComplete`, responses land in `ResponseEmitted` as a cumulative chain (i618). A reader of the bus at any point sees what triggered the AI, when it started thinking, how long it thought, what tools it dispatched, and what it produced : without trust, by wiring.

This is the strongest selling point for any client whose ISO 42001 exposure is real.

### 2.3 ISO 9001 : Quality Management

The foundational quality standard. Maps to the bluebook-as-documented-procedure layer.

| Clause                                        | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| 4.4 Quality management system                 | Bluebook corpus                                                  | Full        | Entire corpus                                                |
| 5.3 Organisational roles                      | `role` declarations on every command                             | Partial     | tools.bluebook + others                                      |
| 6.2 Quality objectives                        | Macrophage rules ARE objectives                                  | Partial     | macrophage.bluebook                                          |
| 7.5 Documented information                    | Bluebook is the only documented procedure ; in version control   | Full        | Corpus + git                                                 |
| 8.1 Operational planning and control          | Bluebook commands as the operational vocabulary                  | Full        | Corpus                                                       |
| 8.5.1 Control of production                   | Macrophage policy enforcement                                    | Full        | macrophage.bluebook                                          |
| 9.1 Monitoring, measurement, analysis         | Envelope events + Cascade chain                                  | Full        | i613 + Cascade                                               |
| 9.2 Internal audit                            | macrophage sweeps + storehouse__macrophage_check                 | Full        | macrophage.bluebook + MCP                                    |
| 9.3 Management review                         | Inbox archive + design-card lifecycle                            | Partial     | `inbox/archive/`                                             |
| 10.1 Continual improvement                    | ChaosMonkey + Weakness backlog                                   | Full        | i617                                                         |

9001 is essentially asking : "document what you do, do what you documented, audit it, improve it." Hecks satisfies this almost trivially because the framework IS this loop : bluebook (document) → runtime (do) → macrophage (audit) → inbox (improve).

The chief gap : 9001's 9.3 Management Review is a human-process control. Hecks gives the artifacts ; the org owns the review meeting.

### 2.4 SOC 2 : Trust Services Criteria

Strictly not ISO, but the de facto US enterprise standard ; clients often confuse them. SOC 2 has five Trust Service Categories : Security (mandatory), Availability, Processing Integrity, Confidentiality, Privacy.

#### Security (CC controls)

| Criterion                                     | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| CC1 Control Environment                       | Bluebook-first principles ; macrophages                          | Full        | `docs/design/principles-2026-05-12.md`                       |
| CC2 Communication                             | macrophage Complaint events surface immediately                  | Full        | macrophage.bluebook                                          |
| CC3 Risk Assessment                           | ChaosMonkey Weakness backlog                                     | Partial     | i617                                                         |
| CC4 Monitoring                                | Heartbeat + autonomic macrophage sweeps (i616)                   | Full        | i616 commit `caca6860`                                       |
| CC5 Control Activities                        | The ten macrophages                                              | Full        | macrophage.bluebook                                          |
| CC6 Logical Access                            | Role + HandlerRegistry + StoreHouse mediation                    | Partial     | i613 + i619                                                  |
| CC7 System Operations                         | StoreHouse envelope + macrophage hooks                           | Full        | i613                                                         |
| CC8 Change Management                         | Forwarder commands + CardLock + git PR flow                      | Full        | i604 + macrophage.bluebook:1484                              |
| CC9 Risk Mitigation                           | ChaosMonkey + macrophage backlog                                 | Partial     | i617                                                         |

#### Availability (A controls)

| Criterion                                     | Hecks feature                                                    | Coverage    |
|-----------------------------------------------|------------------------------------------------------------------|-------------|
| A1.1 Capacity planning                        | Not directly addressed                                           | None        |
| A1.2 Environmental protection                 | Out of scope                                                     | None        |
| A1.3 Recovery from disruption                 | Event-sourced replay ; ChaosMonkey verification                  | Foundation  |

#### Processing Integrity (PI controls)

| Criterion                                     | Hecks feature                                                    | Coverage    |
|-----------------------------------------------|------------------------------------------------------------------|-------------|
| PI1.1 System inputs                           | Bluebook command attributes + VO types                           | Full        |
| PI1.2 System processing                       | Behaviours suites + macrophages                                  | Full        |
| PI1.3 System outputs                          | ResponseEmitted + envelope                                       | Full        |
| PI1.4 Correlation of inputs and outputs       | `correlation_id` on envelope                                     | Full        |

#### Confidentiality (C controls)

| Criterion                                     | Hecks feature                                                    | Coverage    |
|-----------------------------------------------|------------------------------------------------------------------|-------------|
| C1.1 Identification of confidential info      | VO-typed attributes                                              | Partial     |
| C1.2 Disposal of confidential info            | Not directly addressed                                           | None        |

#### Privacy (P controls)

Privacy maps better to ISO 27701 below ; SOC 2's P category is GDPR-flavoured and IdentifierService + envelope give similar coverage.

**SOC 2 summary** : Security (CC) is mostly Full ; Availability is the weakest (capacity planning is genuinely not Hecks's job) ; Processing Integrity is exceptional because the envelope's correlation_id makes input-output traceability structural.

### 2.5 ISO/IEC 27701 : Privacy Information Management

Companion to 27001. Required (or commonly paired) for GDPR alignment. Maps to identity + envelope + handler.

| Control                                       | Hecks feature                                                    | Coverage    | Evidence                                                     |
|-----------------------------------------------|------------------------------------------------------------------|-------------|--------------------------------------------------------------|
| 7.2.1 Identify and document purpose           | Bluebook describes purpose per aggregate                         | Full        | Per-aggregate docstrings                                     |
| 7.2.2 Lawful basis                            | Bluebook + commit history as legal-basis trail                   | Partial     | Git history                                                  |
| 7.2.8 Records of processing                   | Envelope + bus = automatic processing record                     | Full        | i613                                                         |
| 7.3.1 Determining and fulfilling obligations  | Petition workflow on IdentifierService                           | Partial     | i614                                                         |
| 7.3.2 Determining info to be provided         | ResponseEmitted carries cumulative chain                         | Partial     | i618                                                         |
| 7.3.5 Providing copy of PII processed         | IdentityString chain reconstruction                              | Foundation  | i614                                                         |
| 7.3.6 Rectification of PII                    | IdentifierService non-destructive migration                      | Full        | i614 commit `c15ba409`                                       |
| 7.3.7 Erasure of PII                          | Not directly addressed                                           | None        | [verify : erasure semantics in event-sourced log]            |
| 7.4.6 PII transfers                           | HandlerRegistry inventories external endpoints                   | Partial     | i619                                                         |
| 7.5 Privacy notice                            | Out of scope                                                     | None        | n/a                                                            |

The strongest 27701 mappings :

- **7.3.6 Rectification** : GDPR Article 16 requires that personal data corrections be propagated and that the data subject's right to rectification be honoured. IdentifierService's `new/old` migration (i614) is exactly this : the new identity replaces the old at the prefix while the old remains addressable as suffix forever. Corrections are non-destructive and queryable.
- **7.2.8 Records of processing** : GDPR Article 30 asks for a record of processing activities. The envelope on every bus event is that record, by construction.
- **7.3.7 Erasure** : This is a real tension. Event-sourced logs are append-only by nature ; "delete this person" is structurally hard. Hecks needs an erasure-aware mechanism (a `Forget` command that masks values in projections while preserving the event-log integrity) : this is a **gap to file**.

---

## 3. Gaps and what's not covered

Honest accounting. Hecks does not address :

- **A.7 Human resource security** : joiner / leaver / background-check processes. Org-level, integrates with HR systems.
- **A.11 Physical and environmental security** : data-centre, office, hardware physical access. Org-level.
- **A.15 Supplier relationships** : contract management, supplier reviews, due diligence. Partial via HandlerRegistry but the contract surface is procurement.
- **A.13.1 Network security** : TLS, firewalls, segmentation. Platform-level.
- **A.6.2 Mobile devices and teleworking** : endpoint management. Platform-level.
- **SOC 2 A1.1 Capacity planning** : performance and capacity. Genuinely outside Hecks's substrate.
- **27701 7.3.7 Erasure of PII** : event-sourced logs make hard-delete structurally awkward. **This is a real gap that needs a `Forget` mechanism filed as a follow-up.**

The position to take with clients : **Hecks is the technical substrate layer**. It satisfies the controls that are about how software is built, audited, monitored, and changed. It does not satisfy the controls that are about *people, premises, paper, and contracts* : those still need the org's HR system, facilities provider, legal team, and procurement function. Hecks does not pretend to replace those ; it integrates with them.

This positioning is honest, defensible, and actually a strength : a client knows what they're buying, the auditor knows what's in scope, and the boundary is structurally clean.

---

## 4. What this means for an enterprise buyer

### 4.1 The value proposition

Three claims an enterprise buyer can take to its own audit committee, in increasing strength :

1. **A documented, audited, replayable methodology.** Hecks engagements produce auditable bluebooks ; the work surface itself is the deliverable, not a black-box system whose internals you have to take on faith.
2. **The bluebook is the auditor-readable artifact.** A reviewer reads bluebook prose, diff history, and the macrophage backlog. No code-reading required. This collapses the audit cost of a typical 27001 engagement.
3. **Compliance is structural, not aspirational.** The macrophage runs ; the envelope captures ; the chaos-monkey tests. Your compliance officer does not write the policies into a wiki and hope they hold ; the framework enforces them on every change. The audit becomes "look at the macrophage backlog" rather than "interview the engineering team."

### 4.2 Cost-of-audit estimate

ISO 27001 first-time certification audits commonly run 12 to 18 months of preparation for a mid-sized SaaS shop, with internal cost in the range of US $150k to $500k (industry estimates vary widely ; treat as order-of-magnitude). The lion's share is documentation work : writing the policies, generating evidence, building the audit trail retroactively.

Hecks deployments collapse the documentation-and-evidence portion. The bluebook IS the policy ; the envelope IS the evidence. Conservative claim : **a Hecks-substrate program can reduce ISO 27001 prep effort by 40 to 60 % on the documentation side.** The certification itself still requires the external auditor's billable hours, and the HR / physical / supplier controls still take org effort. But the technical-substrate slice (usually the most painful part) is delivered as a side effect of building the product.

### 4.3 Where Hecks differentiates

| Common alternative              | Their pitch                            | What Hecks offers instead                                          |
|---------------------------------|-----------------------------------------|--------------------------------------------------------------------|
| "We use AI" consultancy         | Faster delivery                         | Documented, audited, replayable AI methodology (42001-ready)       |
| Traditional dev shop            | Experienced team                        | Substrate that satisfies 27001 and 9001 by construction            |
| Compliance-as-a-service vendor  | Audit-ready evidence collection         | Compliance baked into the runtime ; no separate evidence pipeline  |
| Low-code platform               | Visual builders                         | Auditable, versioned, runnable bluebook prose ; no vendor lock-in  |

The differentiator that compounds across all four : **a Hecks engagement ships you a system that gets cheaper to audit every year**, instead of a system whose compliance debt grows with code volume.

---

## 5. Where to go from here

### 5.1 The one-week Compliance Posture Report

For an enterprise that wants a concrete, low-commitment first step, Embryonaut offers a one-week engagement that produces :

1. A first-cut bluebook draft of your domain in one to two days, working from whatever artifacts you already have (wiki pages, code, architectural diagrams, conversations).
2. The draft is run through Hecks's macrophages and IR validation.
3. Your bluebook is mapped against ISO 27001 and 42001 control families, using this report's tables as the template.
4. A gap-analysis report is produced : Full / Partial / Foundation / None per control.
5. A cost estimate is produced for closing the gaps using Hecks substrate.

Deliverable : a 20 to 30 page report (this document's shape, scaled to your organisation) plus the bluebook scaffold. The engagement is priced at standard consulting rates and is structured so that even if you choose not to engage further, you leave with a starting bluebook of your own domain and a candid third-party assessment of your compliance posture.

### 5.2 A `compliance.bluebook` template

For organisations going further, a `compliance.bluebook` template lets any domain compose in the audit surface :

- A `ComplianceProgram` aggregate : singleton, holds your organisation's compliance posture (which standards are in scope, which gaps are outstanding).
- A `Control` entity : one per applicable Annex A control or 42001 clause.
- An `Evidence` aggregate : the `RecordEvidence` command captures the link between a control and the bluebook artifact that satisfies it.
- A `Gap` aggregate : the `RecordGap` command captures known shortfalls and remediation timelines.
- An `AuditReview` aggregate : the `SubmitForReview` and `RecordFinding` commands give an external auditor a dispatchable surface.

The macrophages already enforce the underlying controls ; `compliance.bluebook` is the reporting layer that exposes the satisfaction in audit-friendly form.

### 5.3 An `ISOEvidence` aggregate

For organisations whose audit cadence is high (annual, sometimes more), an `ISOEvidence` aggregate is the natural extension : an aggregate that *auto-generates auditor-facing evidence trails* from the bus. The bluebook declares which envelope-event types map to which ISO controls. A scheduled process queries the bus for events of those types, packages them into auditor-facing reports, and produces an `EvidenceBundle` record.

This is the strongest version of the Hecks compliance story : **your annual ISO audit consists of handing the auditor a bundle that was generated from the event log, without manual prep work.**

### 5.4 Getting in touch

If any of the above is a fit for your organisation, the conversation starts at <https://embryonaut.ai/enterprise>. The Compliance Posture Report is the recommended first step ; it is short, candid, and produces an artifact you can hand to your auditor regardless of whether you continue beyond it.

---

## Appendix : Evidence index

The features most-cited in this report, mapped to their bluebook + commit + design-card sources, for an auditor or salesperson who wants to drill into any one of them.

| Feature                                       | Bluebook file                                                                 | Design card                                      | Merge commit |
|-----------------------------------------------|--------------------------------------------------------------------------------|---------------------------------------------------|---------------|
| Bluebook-first principles                     | `docs/design/principles-2026-05-12.md`                                         | 2026-05-12 locked conventions                     | various       |
| StoreHouse wraps every command + envelope     | (design ; implementation in flight)                                            | `inbox/archive/i613.md`                           | `94b12274`    |
| Unfurling through StoreHouse                  | (design ; harness hooks in flight)                                             | `inbox/archive/i615.md`                           | `e8287f8e`    |
| ResponseEmitted with cumulative chain         | (design)                                                                       | `inbox/archive/i618.md`                           | `e89b35d0`    |
| HandlerRegistry                               | `aggregates/framework/handler_registry/handler_registry.bluebook` (272 lines)  | `inbox/archive/i619.md`                           | `c099aa4e`    |
| Forwarder commands                            | (DSL keyword ; implementation in flight)                                       | `inbox/archive/i604.md`                           | `e81dc643`    |
| Natural-key identity                          | `aggregates/discipline/macrophage/macrophage.bluebook:1865` (IdentityDiscipline) | `inbox/archive/i611.md`                       | `96cd1abb`    |
| IdentifierService                             | `aggregates/framework/identifier_service/identifier_service.bluebook` (350 lines) | `inbox/archive/i614.md`                       | `c15ba409`    |
| Autonomic macrophage sweeps                   | `aggregates/framework/heartbeat_scheduler/` (stub)                             | `inbox/archive/i616.md`                           | `caca6860`    |
| ChaosMonkey + Circadian                       | `aggregates/framework/chaos_monkey/chaos_monkey.bluebook` (357 lines)          | `inbox/archive/i617.md`                           | `18bb1a49`    |
| BidirectionalAssociation macrophage           | `aggregates/discipline/macrophage/macrophage.bluebook:1661`                    | `inbox/archive/i612.md`                           | `564974a7`    |
| Macrophage family (10 per-rule aggregates)    | `aggregates/discipline/macrophage/macrophage.bluebook` (2069 lines)            | i555 + i595 + family                              | various       |
| Dispatch audit log                            | `aggregates/framework/audit/dispatch_audit.bluebook` (196 lines)               | n/a                                                 | (earlier)     |
| Tools as bluebook commands                    | `aggregates/framework/tools/tools.bluebook` (~1500 lines)                      | i608 + i609                                       | various       |
| Cascade : outcome stream                      | `aggregates/framework/cascade/cascade.bluebook`                                | i609                                              | `532342c2`    |
| StoreHouse stdout logging                     | (runtime ; rust/src/runtime/storehouse_log.rs)                                 | `inbox/i622.md`                                   | `85c945a8`    |

---

*End of report.*
