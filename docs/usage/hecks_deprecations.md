# hecks_deprecations

Backward-compatible shims with deprecation warnings to ease migration.

## Usage

```ruby
require "hecks_deprecations"

# Now old hash-style access works but warns:
step = Hecks::DomainModel::Behavior::CommandStep.new(command: "CreatePizza")
step[:command]  # => warns "[DEPRECATION]...", returns "CreatePizza"
step.command    # => "CreatePizza" (preferred)
```

## Registering Deprecations

Any module can register a deprecated method:

```ruby
HecksDeprecations.register(MyClass, :old_method) do |*args|
  HecksDeprecations.warn_deprecated(self.class, "old_method")
  new_method(*args)
end
```

## Introspection

```ruby
HecksDeprecations.registered
# => [{ target: CommandStep, method: :[] }, { target: CommandStep, method: :to_h }, ...]
```

## What's Covered

- `CommandStep#[]`, `CommandStep#to_h`
- `BranchStep#[]`, `BranchStep#to_h`
- `ScheduledStep#[]`, `ScheduledStep#to_h`
- `PersistConfig#==` (vs Hash)
- `SendConfig#[]`, `SendConfig#==` (vs Hash)
- `ExtensionConfig#==` (vs Hash)

## Generated examples

Generated examples never `require "hecks_deprecations"` — they always use the current attribute accessor API.
