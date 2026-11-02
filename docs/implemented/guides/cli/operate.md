# operate

Run a domain and look inside it. Use it when a domain is running, or when you want to see what
a running domain holds.

**Concept.** An operation is one thing an operator ran against a domain, and how it ended. The
domain's own commands run through `Operation.run!`, which keeps what they reported. Reads of a
running domain's records are queries on `Introspection`.

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
