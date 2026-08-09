# One command → one role

**Status:** Accepted — implemented (`lib/hecksagain/bluebook/dsl/command_builder.rb`, `spec/dsl_spec.rb`)

## Context

Commands have always carried a single `role` field — `Bluebook::DSL::CommandBuilder#role` was a plain scalar assignment (`def role(value) = @role = value`), and `IR::Command` stored it as one string, never an array. Runtime authorization (`Runtime::CommandRules::Authorization`) already compared the caller's role against that one field.

But nothing stopped a second `role` call inside the same `command` block. A duplicate declaration didn't raise — it silently overwrote the first, so a command could read as authorizing one role in the source while actually authorizing a different one, with no signal to the author that anything had happened.

Not every command needs a role at all: some commands represent system reactions or intentionally unguarded operations, and requiring a role on every command was explicitly out of scope for this decision.

## Decision

`Bluebook::DSL::CommandBuilder#role` now raises `Malformed` if called a second time within the same command:

```ruby
def role(value)
  if @role
    raise Malformed,
          "#{@name} declares role twice — a command has ONE role; " \
          "the second would silently win and the first would " \
          "still look declared"
  end

  @role = value
end
```

Role cardinality becomes explicit as zero-or-one, enforced at declaration time rather than left as an accident of assignment order.

## Consequences

- A command with one role builds and authorizes exactly as before.
- A second `role` declaration is refused immediately, at authoring time, instead of silently changing behavior.
- Role-less commands continue to boot unchanged.
- `IR::Command#role` stays a scalar; no wire-shape change, so no corpus/golden migration was needed.
- Whether every externally-invokable command must eventually declare *exactly* one role (rather than zero-or-one) remains open — this decision only closes the "declared twice" footgun, not the "declared never" question.

## Rejected alternatives

- **An array of roles.** Would invite OR semantics ("any of these roles may act") that nothing in the authorization model supports and that the roadmap explicitly does not want.
- **Requiring a role on every command right now.** A meaningful portion of existing commands (system reactions, intentionally unguarded operations) legitimately declare none; forcing the issue here would have coupled an authoring-safety fix to an unrelated, larger migration.
