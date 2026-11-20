# operate

<!-- prose anchor="Concept" purpose="concept" mentions="command:Operation.run!" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/operate/operate.bluebook" -->
Run a domain and look inside it. Use it when a domain is running, or when you want to see what
a running domain holds.

**Concept.** An operation is one thing an operator ran against a domain, and how it ended. The
domain's own commands run through `Operation.run!`, which keeps what they reported. Reads of a
running domain's records are queries on `Introspection`.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:Operation.run! command:Introspection.stores" supports="code_file:lib/hecks/hecks/operate/operate.bluebook" -->
**Example: run a command and keep its outcome**

```sh
hecks Operation.run! subject.value=examples/banking verb.value=<verb>
```

The reply is the outcome the domain gave, and the run is kept so it can be read back later.

**Example: see what a domain holds**

```sh
hecks Introspection.stores domain.value=examples/banking
```

The reply is each aggregate's current records, as JSON.

**Example: open a console on a domain**

```sh
hecks console! subject.value=examples/banking
```

Opens an interactive console on the domain. It is listed as an everyday command.

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks operate` prints the same list.

<!-- generated:begin cli section=operate -->
### Operation

One thing an operator ran against a domain, and how it ended.

- `hecks Operation.run! [<subject>] [script=] [verb=] [arguments=]`: Dispatch a verb or a step list against a domain and keep what it reported
- `hecks Operation.refresh_projections! <subject>`: Bring every read-model projection of a domain up to date now
- `hecks Operation.redrive_outbox! <subject> [row=] [--claimed]`: Redeliver the reactions a domain's outbox left undelivered, and name the claimed ones that stalled
- `hecks Operation.abandon_outbox_row! <subject> row= [reason=]`: Settle one stalled outbox row as failed without running it: subject.value is the domain, row.value its delivery id or uuid
- `hecks Operation.run_behaviors! <subject>`: Run a domain's behavior tests and keep the verdict
- `hecks Operation.console! [<subject>]`: Open an interactive console on a domain
- `hecks Operation.smoke_test! [<subject>]`: Dispatch one synthesized call per command and report of a wired domain
- `hecks Operation.smoke_http! [<url>] path= [header=] [scheme=] [payload=] [payload_file=] [health_path=] [state_path=]`: Check that a running service refuses bad signatures and accepts a good one
- `hecks Operation.bootstrap_admin! <subject> email= [name=] [role=]`: Admit the first administrator of a domain's membership bluebook and grant them access
- `hecks Operation.follow [<domain>] [aggregate=] [since=] [wait=] [interval=] [names=] [--from-now]`: A domain's persisted event log past a cursor, for tailing it call by call. The domain is a directory (a word with a path separator) or the name of a bluebook the Hecks domain boots, such as Hecks or Tickets; a bare word is a bluebook name first, then a directory; with none named it is the Hecks domain.
- `hecks Operation.feed [<aggregate>] [since=] [names=] [limit=]`: The event tap past a sequence number, filtered by aggregate and event name. It reads the log only, so it boots nothing that acts; `names` is comma separated.

### Host

A running rust/host, and the version and era it last reported.

- `hecks Host.check_era! <host> expected= [timeout=]`: Ask a running host which era it reports, and keep whether it is one that should be running
- `hecks Host.recheck! <to> expected= [timeout=]`: Ask a host already checked which era it reports now

### Introspection

A look at a booted domain, answered by the runtime without changing anything.

- `hecks Introspection.ir [<domain>] [--translations] [--meta]`: The IR a domain's boot produces, as JSON: what golden specs pin and an era hashes.
- `hecks Introspection.shape <domain>`: The storage shape an era's label is minted from: a bluebook file or a directory of them.
- `hecks Introspection.stores <domain> [aggregate=] [record=] [--flat]`: Every aggregate's current records, or one aggregate's, or one record: the head, not the journal.
- `hecks Introspection.history <domain>`: Every journal entry a domain's append-only adapters hold: the whole write history.
- `hecks Introspection.statements <domain> bluebook=`: A bluebook's declared facts, as plain English sentences.
- `hecks Introspection.undo <domain> bluebook= command=`: The command that undoes a declared command, from the bluebook's compensations, or that none is declared.
- `hecks Introspection.narrate [<domain>] [aggregate=]`: A domain read back in English, whole or for one aggregate.
- `hecks Introspection.relationships <domain>`: How the contexts a domain holds depend on each other: shared kernel, customer/supplier, anti-corruption layer, subscription.
- `hecks Introspection.context_map <domain>`: A domain's declared context map drawn as a Mermaid diagram beside its wiring, with what holding the wiring to the map finds.
- `hecks Introspection.world_skeleton <domain>`: A starting .world for a domain: the settings and secrets its bound adapters declare, with no secret's value.
- `hecks Introspection.docs [<domain>] [aggregate=]`: A domain's usage document, whole or for one aggregate.
- `hecks Introspection.project_diagrams <domain> bluebook=`: A bluebook's Mermaid diagrams, as file names mapped to their text; nothing is written.
- `hecks Introspection.glossary <domain> bluebook=`: A bluebook's Ubiquitous Language glossary, as file names mapped to their text; nothing is written.
<!-- generated:end cli -->
