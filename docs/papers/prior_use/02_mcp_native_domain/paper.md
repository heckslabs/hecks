---
title: "MCP-Native Domain Frameworks: Tool Generation, llms.txt Manifests, and Structured-Error Recovery"
authors: "Chris Young"
version: "paper/prior_use-v1-2026-04-24"
commit: "c4a903f3"
date: 2026-04-24
---

# MCP-Native Domain Frameworks

## Tool Generation, `llms.txt` Manifests, and Structured-Error Recovery

**Version:** `paper/prior_use-v1-2026-04-24`
**Repository commit at time of writing:** `c4a903f3`
**Author:** Chris Young

## Abstract

The Model Context Protocol (MCP) has become the de facto surface through
which language-model agents discover and invoke tools. Frameworks that
already have a command vocabulary — an event-sourced aggregate model, for
instance — can expose that vocabulary to agents directly, at no
developer-authoring cost, if the framework is structured to generate the MCP
tool surface from the same IR that drives the command bus. We describe such
a framework (Hecks) in which (i) every declared command becomes an MCP tool
with a structured input schema derived from its attributes; (ii) every
generated domain ships with an `llms.txt` manifest summarising the
aggregates, commands, and queries that exist; and (iii) validator and
runtime errors are emitted in a structured form that an agent can
programmatically recover from rather than a human-string form that requires
re-planning. The concrete claim: a domain authored as a 30-line `.bluebook`
boots as an HTTP-served, MCP-exposed, event-sourced service with an
agent-readable manifest, with no additional wiring. We describe the
generation path, give a worked end-to-end banking example with an agent
session, and place the technique in the public record as prior art.

---

## §1 Introduction

The near-term work pattern for software teams increasingly includes an
agent in the loop. The agent receives a specification, decides which
framework surface to use, invokes it, interprets the result, and loops. The
value a framework offers this loop is proportional to how legibly it exposes
itself. A framework that requires the agent to read source, infer API
shapes, and assemble ad-hoc requests is friction; a framework that offers a
structured tool list with typed inputs and structured errors is leverage.

MCP is the current common protocol for this exposure. An MCP *server*
advertises tools; an *agent* (client) enumerates them, calls one with
arguments that match its declared schema, and receives a structured
response. The protocol itself is simple. What is non-trivial is the
*mapping* from a framework's concepts to MCP tools — particularly for
frameworks whose domain is not flat configuration (REST-style) but a set of
aggregates with commands and policies that cascade.

The alternative to a framework-level MCP surface is an app-level adapter:
every team writes their own tool wrapper for their own domain. This is the
status quo in most enterprise codebases today. The app-level adapter has
two costs. First, it decouples the MCP surface from the domain model, so
changes to the domain silently stop matching the tools. Second, it
duplicates the schema derivation: the same attribute declared on a command
is declared again, by hand, on the MCP tool.

We describe a framework that collapses the gap. The domain is declared
once, in a `.bluebook`; the MCP tool list, the `llms.txt` manifest, the
HTTP handlers, and the command bus handlers are each generated from the
same IR. An agent pointed at the framework's MCP server finds a tool list
isomorphic to the declared commands; an agent fetching `llms.txt` reads a
manifest that describes the aggregates, commands, and queries in prose; an
agent whose tool call violates an invariant receives a structured error
with the rule name, the offending field, and a remediation hint.

This is the paper that describes the shape most relevant to this moment.
The other papers in this collection address partial evaluation, validation
discipline, and cascade-testing. This one addresses the surface that
agents actually see.

### §1.1 Contribution

The contributions are:

1. **Command-to-MCP-tool generation.** Every command declared in a
   `.bluebook` becomes an MCP tool whose input schema derives from the
   command's `attribute` and `reference_to` declarations. Implementation at
   `lib/hecks_ai/mcp_server.rb` and `lib/hecks_ai/domain_server.rb`; tool
   groups at `lib/hecks_ai/{aggregate_tools,inspect_tools,build_tools,play_tools}.rb`.
2. **`llms.txt` manifest per generated domain.** Every Hecks-generated
   domain ships with an `llms.txt` at its root describing the aggregates,
   commands, and queries in a compact prose + type format. Evidence:
   `examples/pizzas_domain/llms.txt`,
   `examples/governance/{compliance,operations,risk_assessment,identity,model_registry}_domain/llms.txt`,
   and the multi-domain examples.
3. **Structured-error JSON for programmatic recovery.** Validator errors
   (from Paper 1 in this collection) are emitted with rule name, location,
   and remediation fields; runtime errors (invariant violation,
   missing-reference, gate denial) carry the same structure. An agent
   receives enough to retry with an edit rather than re-plan.
4. **Two MCP modes: authoring vs. serving.** A single `hecks mcp` binary
   exposes the authoring surface (create/load sessions, add/remove
   aggregates, validate, build, serve); a per-domain `hecks_ai::DomainServer`
   exposes the *running* surface (dispatch commands, run queries, read event
   log). The separation mirrors the two audiences: authoring agents editing
   a domain under design, and operating agents acting on a live domain.
5. **Worked end-to-end banking session** (§7) showing an agent (i)
   discovering the domain via `llms.txt`, (ii) enumerating tools via MCP,
   (iii) dispatching a command, (iv) receiving a structured error, and (v)
   retrying successfully.

### §1.2 Paper organisation

§2 motivates the framework-level placement of the MCP surface. §3 describes
the command-to-tool generation. §4 describes `llms.txt`. §5 describes
structured errors. §6 describes the two-mode design (authoring vs. serving).
§7 walks an end-to-end banking session. §8 compares to adjacent work. §9
enumerates novel claims. §10 closes.

---

## §2 Why Framework-Level, Not App-Level

An app-level MCP adapter is the obvious place to start. A team that already
has a domain model hand-writes a `tools.py` or `tools.rb`, maps each
business action to a tool, declares a schema, and returns strings. This
works. The cost is subtle and accumulates.

The *derivation gap*. Every declared attribute on a command gets hand-copied
onto the tool schema. The two diverge over time. A field added to the
command but forgotten on the tool is invisible until the agent asks for it;
a field removed from the command but left on the tool produces a phantom
input the domain ignores. The gap is maintained by discipline.

The *error gap*. Domain errors (invariant violations, missing references,
gate denials) have a structure the domain already knows. The hand-written
adapter flattens them to strings because flattening is easy and preserving
structure is a discipline nobody pays for. The agent receives strings and
loses the ability to retry programmatically.

The *coverage gap*. Commands get tool wrappers; queries, lifecycles, and
policies often do not. The agent's view of the domain is whatever the
adapter author thought to expose. Introspection of the unexposed surface
requires reading the source.

The *drift signature*. When the domain evolves, the adapter drifts. There
is no test that asserts the adapter and the domain agree, because the
adapter is hand-written per app and the domain has no notion of being
agent-exposed.

Placing the MCP surface at the framework level closes each gap structurally.
The surface is generated from the same IR as the runtime; there is one
source of truth; coverage is total (every command becomes a tool); drift is
eliminated because there is no second place to maintain.

The observation is not novel in the abstract — REST-autogeneration from
models has a long history (Rails ActiveResource, Django REST Framework,
GraphQL schema introspection). The specific claim here is that an MCP
surface for a *DDD* framework — with aggregates, commands, cascading
policies, and structured errors — has the same structural argument behind
it, and has not been widely pursued because most DDD frameworks were
written before agents were a first-class client.

---

## §3 Command-to-MCP-Tool Generation

Every command declared in a Hecks bluebook compiles to an MCP tool. The
mapping is one-to-one, by design.

Given a command:

```ruby
command "Deposit" do
  role "Teller"
  goal "Credit an account"
  reference_to Account
  attribute :amount, Integer
end
```

the generator emits a tool whose schema is:

```json
{
  "name": "Deposit",
  "description": "Credit an account",
  "inputSchema": {
    "type": "object",
    "properties": {
      "account_id": { "type": "string",  "description": "reference_to Account" },
      "amount":     { "type": "integer", "description": "amount" }
    },
    "required": ["account_id", "amount"]
  }
}
```

The schema fields are each derivable from the bluebook:

- `name` = command name.
- `description` = command `goal` declaration (falls back to `role` +
  command name when `goal` is absent).
- `properties.<attr>.type` = JSON Schema mapping of the attribute's
  declared type, via the Hecks `TypeContract`
  (`lib/hecks/conventions/type_contract.rb`). Integer → integer, String →
  string, Float → number, Boolean → boolean, list types → arrays, nested
  value objects → objects.
- `properties.<ref>_id.type` = string (the convention for a
  `reference_to X` is a string identifier whose target is named
  `<x>_id`).
- `required` = every attribute without a default, plus every
  `reference_to`.

The MCP server itself is `lib/hecks_ai/domain_server.rb`: it boots a domain
from a bluebook, walks the IR, emits one tool per command, and dispatches
tool calls through the same command bus that HTTP handlers use. A successful
tool call returns the emitted events; a failing one returns a structured
error (§5).

### §3.1 Queries and lifecycle transitions

Queries (`query "Pending" do where(status: "pending") end`) become
read-only tools that accept the query's block arguments as inputs and
return the matching rows in a serialised form. Lifecycle transitions
(`transition "CancelOrder" => "cancelled"`) become command tools on the
declaring aggregate; the transition is dispatched through the normal
command path and the resulting event is returned.

### §3.2 Cross-aggregate policies are not tools

Policies, which cascade commands internally in response to events, are *not*
exposed as tools. They are internal wiring. Exposing them would let an
agent trigger a policy directly, bypassing the command whose emission was
supposed to invoke it — a footgun. Policies are visible only in `llms.txt`
as documentation; they are not callable.

---

## §4 The `llms.txt` Manifest

Every generated domain ships with an `llms.txt` at its root. The format is
intentionally simple prose-plus-types: it is what a reader-model would read
first before enumerating tools.

Sample (from `examples/pizzas_domain/llms.txt`):

```
# llms.txt

## Domain: Pizzas

### Aggregate: Pizza

**Attributes:**
- `name`: String
- `description`: String
- `toppings`: list_of(Topping)

**Commands:**
- `CreatePizza(name: String, description: String)` -> CreatedPizza
- `AddTopping(pizza_id: reference_to(Pizza), name: String, amount: Integer)` -> AddedTopping

**Queries:**
- ByDescription

### Aggregate: Order

**Attributes:**
- `customer_name`: String
- `items`: list_of(OrderItem)
- `status`: String

**Commands:**
- `PlaceOrder(customer_name: String, pizza_id: String, quantity: Integer)` -> PlacedOrder
- `CancelOrder(order_id: reference_to(Order))` -> CanceledOrder
```

The file is generated deterministically from the IR; it is not hand-edited.
An agent that has access to the domain's root directory can `fetch
llms.txt` before enumerating MCP tools; the manifest summarises the domain
in roughly a page, while the MCP tool list gives machine-invocable
schemas for each operation.

The two surfaces are complementary. `llms.txt` is a *manifest* — a reading
aid that names and describes the domain's shape. The MCP tool list is the
*calling surface* — the set of structured inputs the domain accepts. An
agent typically reads the manifest to plan; it invokes the tools to act.

### §4.1 Manifest freshness

Every domain generation rewrites `llms.txt` from IR. There is no hand
maintenance path. A new command added to a bluebook is present in
`llms.txt` on the next build; a removed command disappears. This is the
*structural* counterpart to the MCP tool list: the two surfaces drift
together, by construction, because they are emitted from the same pass.

---

## §5 Structured Errors for Programmatic Recovery

A tool call that violates the domain's rules returns a structured error.
The structure is explicit: each error carries a `kind` field, a
`location` field naming the offending element, and a `remediation` field
with a concrete next-edit suggestion. Example (validator violation):

```json
{
  "kind": "distinct_reference_aliases",
  "location": { "aggregate": "Account", "references": ["Customer", "Customer"] },
  "message": "Account has 2 references to Customer with duplicate alias :customer",
  "remediation": "Add `as: :<alias>` to each reference so they have distinct names",
  "rule": "validator_shape:distinct_reference_aliases"
}
```

Runtime errors share the shape. An invariant violation:

```json
{
  "kind": "invariant_violation",
  "location": { "aggregate": "Pizza", "value_object": "Topping", "attribute": "amount" },
  "message": "amount must be positive",
  "remediation": "Supply amount > 0",
  "rule": "bluebook:Pizza.Topping.amount.positive"
}
```

A gate denial:

```json
{
  "kind": "gate_denied",
  "location": { "gate": "SpecializeRun", "command": "Specialize" },
  "message": "Specialize requires :autophagy capability",
  "remediation": "Ensure the calling context has :autophagy declared in its .hecksagon",
  "rule": "hecksagon:SpecializeRun.autophagy"
}
```

The remediation field is the connective tissue between Paper 1's validator
discipline and the agent loop. An agent receiving a structured error can
decide mechanically: if `kind == "invariant_violation"`, modify the input
to satisfy the invariant and retry; if `kind == "distinct_reference_aliases"`,
edit the bluebook to add aliases and re-validate; if `kind == "gate_denied"`,
surface to the user for capability review.

### §5.1 Why the structure is load-bearing

The alternative — returning human-string errors — forces the agent to do
text matching on error messages, which is brittle across locales and
phrasings, and which collapses multi-dimensional information (rule, location,
remediation) into a single axis. The structured form preserves the axes
and lets each be addressed programmatically.

This is a specific case of a broader principle: frameworks that are
agent-aware should return *data*, not *prose rendered from data*. Prose
rendering is a consumer concern.

---

## §6 Two MCP Modes: Authoring vs. Serving

Hecks exposes two MCP endpoints with distinct audiences.

### §6.1 The authoring server (`hecks mcp`)

Implementation: `lib/hecks_ai/mcp_server.rb`. Tool groups:

- `SessionTools` — create/load a `Workshop`. A workshop is an in-memory,
  modifiable domain under construction.
- `AggregateTools` — add/remove aggregates, commands, attributes,
  references within the current workshop.
- `ServiceTools` — add cross-aggregate services (domain services that
  orchestrate multiple aggregates' commands in a declared order).
- `InspectTools` — read-only domain introspection.
- `BuildTools` — validate, build, save, serve. `build` emits the generated
  gem/binary; `serve` boots an HTTP + MCP server against the current
  workshop; `save` persists the bluebook to disk.
- `PlayTools` — an interactive playground for dispatching commands and
  inspecting the event log without leaving the MCP session.
- `GovernanceTools` — governance checks against world-level concerns.

The authoring server is the surface an agent uses to *design* a domain.
It is the MCP equivalent of a REPL for Hecks. Adding an aggregate through
the authoring surface emits a tool call with a structured schema; the
change is reflected in the workshop's in-memory IR and can be validated
immediately via `BuildTools::validate`.

### §6.2 The running server (`hecks_ai::DomainServer`)

Implementation: `lib/hecks_ai/domain_server.rb`. This server boots a
*built* domain from disk, exposes the domain's commands and queries as
MCP tools, and dispatches tool calls through the same command bus the
HTTP frontend uses. A single event log is shared between all paths into
the domain — HTTP, CLI, and MCP — so an agent acting through MCP produces
events indistinguishable from a user acting through the web form.

### §6.3 The distinction matters

The two servers address two phases. A team evaluating Hecks for a new
domain uses the authoring server; agents on the team iterate on the
bluebook with the author, running `validate` and `play` tools to test
shapes. Once the domain is stable, the team runs `build`, commits the
generated domain, and deploys. Agents that will operate the deployed
domain connect to the running server, which exposes a narrower surface
(just commands and queries) with persistence backing.

Conflating the two would be a mistake. An authoring tool that could also
dispatch commands into a live production event log would be dangerous; a
running server that accepted `add_aggregate` would not be idempotent with
the bluebook on disk. The two servers split because the phases split.

---

## §7 Worked End-to-End: Banking via an Agent

This section walks an agent session against the `examples/banking` domain.
The session is real in shape; we present it as a labelled transcript with
the exchanges an operator would see.

**Setup.** The banking domain is built from
`examples/banking/hecks/banking.bluebook`. Its running server is started:

```sh
$ hecks serve examples/banking --mcp
# HTTP on :4567, MCP on stdio
```

### §7.1 Agent: discover the domain

The agent fetches `llms.txt`:

```
## Domain: Banking

### Aggregate: Customer
**Attributes:** name: String, email: String, status: String
**Commands:**
- RegisterCustomer(name: String, email: String) -> RegisteredCustomer
- SuspendCustomer(customer_id: reference_to(Customer)) -> SuspendedCustomer

### Aggregate: Account
**Attributes:** customer_id: reference_to(Customer), balance: Float,
                account_type: String, daily_limit: Integer, status: String
**Commands:**
- OpenAccount(customer_id: reference_to(Customer), account_type: String,
              daily_limit: Integer) -> OpenedAccount
- Deposit(account_id: reference_to(Account), amount: Float) -> Deposited
- Withdraw(account_id: reference_to(Account), amount: Float) -> Withdrew
- CloseAccount(account_id: reference_to(Account)) -> ClosedAccount

### Aggregate: Transfer
**Attributes:** from_account_id: reference_to(Account),
                to_account_id: reference_to(Account),
                amount: Float, status: String
**Commands:**
- InitiateTransfer(from_account_id: reference_to(Account),
                   to_account_id: reference_to(Account),
                   amount: Float) -> InitiatedTransfer

### Aggregate: Loan
**Attributes:** customer_id: reference_to(Customer),
                account_id: reference_to(Account),
                principal: Float, rate: Float, term_months: Integer
**Commands:**
- IssueLoan(...) -> IssuedLoan
- MakePayment(loan_id, amount) -> MadePayment
- DefaultLoan(loan_id) -> DefaultedLoan

### Policies:
- DisburseFunds: on IssuedLoan -> Deposit(account_id, principal -> amount)
- SuspendOnDefault: on DefaultedLoan -> SuspendCustomer (guarded)
```

### §7.2 Agent: enumerate tools

The MCP `tools/list` response returns one tool per command declared in the
bluebook (plus read-only tools for each query). The agent sees 12 tools
total across the four aggregates.

### §7.3 Agent: dispatch a command

The agent plans: "Open an account for a new customer and make an initial
deposit." It calls `RegisterCustomer`:

```json
{ "tool": "RegisterCustomer",
  "arguments": { "name": "Ada Lovelace", "email": "ada@example.com" } }
```

and receives:

```json
{ "events": [
    { "type": "RegisteredCustomer",
      "aggregate_id": "customer-01J...",
      "occurred_at": "2026-04-24T14:02:11Z",
      "attributes": { "name": "Ada Lovelace", "email": "ada@example.com" } }
  ] }
```

The `customer-01J...` identifier is the opaque reference the agent uses for
the next call.

### §7.4 Agent: trigger a structured error

The agent calls `Withdraw` on the new account with an impossible amount:

```json
{ "tool": "Withdraw",
  "arguments": { "account_id": "account-01J...", "amount": 50000 } }
```

A `specification "LargeWithdrawal"` on `Account` rejects withdrawals over
`10_000`. The server returns:

```json
{ "error": {
    "kind": "specification_failed",
    "location": { "aggregate": "Account", "specification": "LargeWithdrawal" },
    "message": "withdrawal.amount > 10_000 — denied",
    "remediation": "Supply amount ≤ 10000, or call ApproveLargeWithdrawal first",
    "rule": "bluebook:Account.LargeWithdrawal"
  }
}
```

### §7.5 Agent: retry programmatically

The agent reads `kind: "specification_failed"` and
`remediation: "Supply amount ≤ 10000 ..."`. It retries with
`amount: 9500`. The retry succeeds. The agent did not re-plan; it edited
its input along the remediation axis and continued.

### §7.6 Cascade visibility

The agent then issues a loan (`IssueLoan`) which cascades into `Deposit`
via the `DisburseFunds` policy. The tool response includes the full
ordered event list from the cascade:

```json
{ "events": [
    { "type": "IssuedLoan",   "aggregate_id": "loan-01J...",    ... },
    { "type": "Deposited",    "aggregate_id": "account-01J...", ... }
  ] }
```

The agent sees both events because the running server returns the full
cascade as part of the tool result, not only the directly-dispatched event.
This is the agent-facing manifestation of the *cascade lockdown* property
that Paper 4 of this collection discusses at length: the policy chain is
observable and deterministic, so an agent can rely on what the tool call
produced.

---

## §8 Related Work

**MCP reference servers.** The MCP specification ships several reference
servers (filesystem, fetch, git, GitHub). These expose low-level
capabilities, not domain-level ones; their shape is generic. A framework
that *generates* MCP tools from a domain model is a different scope.

**Autogenerated REST from models.** Rails ActiveResource, Django REST
Framework, Hanami actions, tRPC, and similar tools generate HTTP
endpoints from models. The structural argument is the same — one source
of truth, the HTTP surface is derived. MCP-from-commands is the
agent-era restatement of that argument.

**GraphQL schema introspection.** GraphQL has long offered machine
introspection of types, fields, and arguments. An agent pointed at a
GraphQL endpoint can read the schema and plan queries. The gap vs. MCP
is at the *action* axis: GraphQL mutations are a thin wrapper over the
query language; MCP tools expose the action with structured input and
structured output including error shape, which is closer to how agents
want to work.

**OpenAPI-driven agents.** Agents that consume OpenAPI specifications to
plan calls against a REST API have been available since before MCP. The
limitation is error: OpenAPI describes responses shape-wise but rarely
structures errors consistently. MCP with structured errors is an
improvement on the OpenAPI-based shape.

**LangChain / function-calling.** Tool-calling frameworks (LangChain,
LlamaIndex, OpenAI function-calling) let developers wrap callables as
agent-exposed tools. These are app-level adapters; they sit where the
hand-written adapter sits in §2. The framework-level placement we
describe is orthogonal: the same function-calling primitives would
consume Hecks's generated tool list without further work.

**`llms.txt`.** The `llms.txt` convention was proposed as a human-written
manifest for a website. We use the same filename and convention for the
generated per-domain manifest. The extension is that our `llms.txt` is
emitted from IR rather than hand-written, and that it lists the domain's
callable surface rather than general site navigation.

**DDD frameworks with agent exposure.** To the author's knowledge no
widely-deployed DDD framework currently generates an MCP tool list from
its command vocabulary or ships a per-domain `llms.txt`. Several DDD
frameworks expose introspection APIs (Axon, EventFlow); those APIs are
framework-specific, not MCP.

---

## §9 Techniques and Novel Claims

1. **Command-to-MCP-tool generation one-to-one from the declared IR.**
   Every `command` declaration in a `.bluebook` becomes an MCP tool with
   a JSON Schema derived from its attributes and references.
   Implementation: `lib/hecks_ai/domain_server.rb`.
2. **Type mapping via a shared contract.**
   `lib/hecks/conventions/type_contract.rb` maps declared types to JSON
   Schema, Go, TypeScript, and SQL simultaneously; the MCP tool schema
   is one consumer of the same contract the HTTP and Go targets consume.
3. **Per-domain `llms.txt` emitted from IR.** Every generated Hecks domain
   ships with `llms.txt`; evidence at
   `examples/pizzas_domain/llms.txt` and the five governance
   sub-domains. The manifest is regenerated on every build and is not
   hand-edited.
4. **Structured error shape with `kind`, `location`, `message`,
   `remediation`, `rule`.** Validator errors, invariant violations, gate
   denials, and specification failures all share the shape.
5. **Remediation field as connective tissue to the validator discipline.**
   Every structured error carries a concrete next-edit suggestion derived
   from the same `error_template` fields used by the `hecks verify`
   command-line tool — so an agent and a developer read the same advice.
6. **Two-mode MCP surface: authoring (`hecks mcp`) vs. serving
   (`DomainServer`).** The authoring surface exposes tools for editing a
   domain under construction; the serving surface exposes tools for
   operating a built domain. `lib/hecks_ai/mcp_server.rb` vs.
   `lib/hecks_ai/domain_server.rb`.
7. **Tool-group composition in the authoring server.** Seven tool groups
   (`SessionTools`, `AggregateTools`, `ServiceTools`, `InspectTools`,
   `BuildTools`, `PlayTools`, `GovernanceTools`) registered with a
   single shared context. Each group is a separate Ruby module; none
   depends on another.
8. **Policies deliberately not exposed as tools.** Cascading policies are
   internal wiring; exposing them would let an agent bypass the causal
   chain. `llms.txt` documents them; the MCP tool list does not include
   them.
9. **Event-cascade visibility in tool results.** A command that triggers
   a policy returns the *full ordered event list* from the cascade, not
   just the directly-dispatched event. An agent can reason about
   downstream effects from the tool result alone.
10. **Workshop as in-memory IR for authoring sessions.** The authoring
    session holds a modifiable domain in memory; edits are validated
    immediately; `build` and `save` commit to disk. This makes the
    authoring loop fast and the disk state predictable.
11. **Structured reference identifiers.** A `reference_to X` becomes a
    `<x>_id: string` input field. The convention is uniform across tool
    generation, HTTP, and event payloads, so the same identifier shape
    crosses all surfaces an agent or user might touch.

---

## §10 Discussion

### §10.1 Why this paper matters more than the others, right now

The shape of agent-developer collaboration is settling. Structured tool
surfaces, manifest files, and recoverable errors are becoming the default
expectation. A framework that ships these out of the box is a magnitude
faster for an agent to use than one that requires an app-level adapter.
The rest of Hecks's contributions — validation, cascade lockdown, partial
evaluation — are each independently valuable, but they mature on multi-year
timescales. The MCP-native surface matures on a quarterly timescale. That
is what makes this paper's claims time-sensitive.

### §10.2 Why `llms.txt` and MCP together, not one or the other

`llms.txt` is reading; MCP is action. An agent planning a multi-step
interaction reads the manifest to decide what to try, then dispatches
through the tool list. An agent given only MCP sees the tool list but has
no narrative context about the domain; an agent given only `llms.txt`
sees the narrative but has no structured calling surface. The two
together give an agent the reading material and the invocation surface
it expects.

### §10.3 Why commands are tools and policies are not

Commands are the domain's *requested* operations. They are the entries an
outside party — user, agent, cron job — asks for. Policies are *reactive*;
they fire in response to events. A policy is not something an outside
party asks for; it is something the domain does on the outside party's
behalf. Exposing a policy as a tool would invert the direction and would
let an agent bypass the causal chain (triggering `Deposit` directly in
response to an agent call, rather than as a consequence of `IssueLoan`).
We deliberately refuse that surface. Policies are documented, not
callable.

### §10.4 On the adoption gravity of the DSL

A team evaluating Hecks for an agent-era project sees: a 30-line
bluebook becomes a running service with MCP tools, an `llms.txt`, a
command bus, an event log, structured errors, and HTTP. The unit of
progress — from zero to exposed domain — is a minute. This is not a
DDD-scoped pitch; it is a Rails-scoped pitch, in the sense that it
competes with a framework-generation tool on speed rather than with a
discipline book on rigour. The DDD patterns are acquired by the
developer by *writing the domain*, not by reading Evans first. The MCP
surface is what makes the generated artefact immediately useful to the
agent the developer is probably pairing with.

---

## §11 Conclusion

A framework that already models its domain as a set of aggregates,
commands, and policies has everything it needs to generate an MCP surface,
an `llms.txt` manifest, and structured errors — at no developer-authoring
cost — if those surfaces are emitted from the same IR that drives the
command bus. We describe such a framework, give a worked end-to-end agent
session, and place the technique in the public record as prior art at
commit `c4a903f3`. The artefacts are reproducible from
`lib/hecks_ai/`, `examples/banking/`, `examples/pizzas_domain/`, and the
`.bluebook` files those paths reference.
