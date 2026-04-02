# World Concerns Onboarding — `hecks new`

When you create a new Hecks domain, you are invited to declare world concerns upfront. Each goal maps to a real runtime extension that enforces it — this is not aspiration, it is enforcement.

## The prompt

```
$ hecks new my_domain

Welcome to Hecks.

Hecks is built on the belief that software affects living beings.
The domain you're about to model will touch some of them.

Would you like to declare world concerns for this domain?

  1. Yes — walk me through them
  2. Skip for now — I'll add them later
  3. This doesn't apply to my project

> 1

Available concerns (each wires in a real extension):

  privacy        — mark sensitive fields, require consent  (extend :pii)
  transparency   — log all state changes                   (extend :audit)
  consent        — require actors for all commands         (extend :auth)
  security       — fail-closed auth and CSRF protection    (extend :auth)
  equity         — row-level access, no gatekeeping        (extend :tenancy)
  sustainability — rate limiting and resource bounds       (extend :rate_limit)

Select concerns (comma-separated, or Enter to skip):
> privacy, consent

Domain created. World concerns declared.
```

## Generated Bluebook (privacy + consent selected)

```ruby
Hecks.domain "MyDomain" do
  world_concerns :privacy, :consent
  extend :pii
  extend :auth

  aggregate "Example" do
    attribute :name, String
    validation :name, presence: true
    command "CreateExample" do
      attribute :name, String
    end
  end
end
```

Note: `consent` and `security` both map to `:auth` — selecting both emits `extend :auth` only once.

## Extension mapping

| Goal | Extension |
|------|-----------|
| `privacy` | `:pii` |
| `transparency` | `:audit` |
| `consent` | `:auth` |
| `security` | `:auth` |
| `equity` | `:tenancy` |
| `sustainability` | `:rate_limit` |

## Choice 2 — skip

Generates a plain domain with no world_concerns or extend calls.

## Choice 3 — doesn't apply

Generates a domain with a commented stub for later:

```ruby
Hecks.domain "MyDomain" do
  # world_concerns :privacy, :consent  # add when ready

  aggregate "Example" do
    attribute :name, String
    validation :name, presence: true
    command "CreateExample" do
      attribute :name, String
    end
  end
end
```

## CI / non-interactive mode

Use `--no-world-goals` to skip the prompt entirely:

```
$ hecks new my_domain --no-world-goals
```

The prompt is also skipped automatically when stdin is not a TTY.

## Invalid input

Unrecognized concern names are silently filtered out. Only the six valid goals
(`privacy`, `transparency`, `consent`, `security`, `equity`, `sustainability`) are kept.
