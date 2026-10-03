# AI-native development

The thesis from the README's
[Why](../../../README.md#why-this-gets-sharper-with-ai-generated-code)
made concrete: a coding agent working on a hecks domain has a
narrower, checked surface to operate on than one editing an arbitrary
codebase, and a real, tested way to operate on it without shelling out
to ad hoc scripts.

## The storehouse door

`hecks mcp` (backed by `Hecks::Storehouse`,
`lib/hecks/storehouse.rb`, tested by `spec/storehouse_spec.rb`) is an
MCP server exposing one bus, the [storehouse](../../../README.md#storehouse),
for *every* booted domain: `dispatch`
(commands, with `dry_run` and batched steps), `query`, `state`,
`history`, `catalog`, `describe`, `validate` (a deep model-check pass),
`domains` (auto-discovery, so a caller that doesn't already know a
path can find one), `behaviors`, and `follow` (tails a domain's own
audit log live). Every call carries a required `summary` and, for
`dispatch`/`query`, a caller identity (`role`/`actor_id`) bound for the
call — checked against a role-gated command's own declared role, the
same string-vs-`Governance::RoleAssignment` check ADR 0025 gives every
other caller. `dispatch` requires it: a command that declares a role
refuses rather than runs when no caller is bound. `query`'s own
authorization runs on a separate mechanism (tenant scope) that `role`
does not gate, so a query executes unbound either way.

The MCP tools are thin wrappers over `Hecks::Storehouse`'s own module
functions, so the same calls run in-process. Against the pizzas domain on
the in-memory adapter:

<!-- doctest:boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))
Hecks.hecksagon("Pizzas") do
  attaches "Governance"
  Pizzas::Order.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
-->

```ruby
catalog = Hecks::Storehouse.catalog(runtime: runtime)
catalog[:aggregates].first[:commands]   # => ["add_topping!", "create_pizza!", "purchase!"]

pizza = { name: "Diavola", pizza: { price_cents: { cents: 1400 }, size: "large" } }

unbound = Hecks::Storehouse.dispatch(runtime: runtime, command: "create_pizza", summary: "add a pizza", args: pizza)
unbound[:ok]                             # => false

chef = Hecks::Storehouse.dispatch(runtime: runtime, command: "create_pizza", summary: "add a pizza", args: pizza, role: "Chef")
chef[:events].map { |event| event[:name] } # => ["PizzaCreated"]
```

`CreatePizza` declares `role "Chef"`, so the unbound call comes back
refused, as data, and the call that names a role goes through.

## What the identity check is, and is not

Identity here is self-asserted by whoever is calling, not authenticated
— this bus checks a stated `role`/`actor_id` consistently, it does not
verify who is actually on the other end (see `hecks mcp`'s
header for what that does and does not guard against). Every
domain-scoped tool's `domain:`/`under:` is confined to
`Hecks::Storehouse::BOOT_ROOT` (the project directory by default) —
`Hecks.boot` loads real Ruby, and this bus refuses to boot one from
outside its own root. `hecks serve_query_ir_mcp` is a smaller, older,
read-only sibling exposing structural queries over the language itself
(`lib/hecks/query_ir.rb`) — meta-tooling for working on hecks, not on a
business domain. Both speak MCP over stdio only and refuse to start
otherwise (`Hecks::McpStdioGuard`: no network argument or `HECKS_MCP_*`
option, no IP socket as stdin or stdout), and both print an identity
warning on stderr at startup. The door is unauthenticated beyond the
caller-asserted `role`/`actor_id` above, and its readers (`state`,
`events`, `history`, `follow`, `describe`, `catalog`) take no identity;
the query-IR server asks for none. Neither should be exposed over a
network — [ADR
0062](../../decisions/0062-mcp-servers-need-real-authentication-before-any-network-transport.md)
proposes what a network transport would need first. Both are
registered in `.mcp.json` in this repository.

## What this means in practice

An agent can inspect a domain's shape, dispatch a real command, read
back events and state, and statically validate a change — all through
the same closed, checked vocabulary a human reads in the bluebook —
instead of grepping and editing arbitrary Ruby files. It does not mean
the agent is unsupervised, or that the vocabulary is complete (see
[Project status](project-status.md)); it means the interface an agent
operates through is the same constrained one the README argues for.
