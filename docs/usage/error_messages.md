# Friendly Error Messages

Every validation error includes a **hint** field that suggests how to fix
the issue. Hints appear in the CLI, in `ValidationError` exception
messages, and in the structured `to_h` output for programmatic access.

## CLI output

When `hecks validate` or `hecks build` encounters a validation failure,
each error is printed in red with a cyan "Fix:" line underneath:

```
$ hecks validate
Domain validation failed:
  - Widget has no commands
    Fix: Add at least one command: command 'CreateWidget' do attribute :name, String end
  - Order references unknown aggregate: Gadget
    Fix: Available aggregates: Widget, Invoice
```

## Programmatic access

Each validation error is a `ValidationMessage` with `message` and `hint`:

```ruby
validator = Hecks::Validator.new(domain)
validator.valid?

validator.errors.each do |err|
  puts err.message          # => "Widget has no commands"
  puts err.hint             # => "Add at least one command: ..."
  puts err.to_h             # => { message: "...", hint: "..." }
end
```

`ValidationMessage` is string-compatible -- it responds to `to_s`,
`include?`, `=~`, `downcase`, and other common String methods, so
existing code that treats errors as plain strings continues to work.

## Exception messages

When a domain is loaded or built, `ValidationError.for_domain` formats
hints inline:

```ruby
begin
  Hecks.load(domain)
rescue Hecks::ValidationError => e
  puts e.message
  # Domain validation failed:
  #   - Widget has no commands
  #     Fix: Add at least one command: command 'CreateWidget' do ...
end
```

## Rules with hints

All built-in validation rules include fix hints:

| Rule | Example hint |
|------|-------------|
| AggregatesHaveCommands | Add at least one command |
| CommandsHaveAttributes | Add at least one attribute |
| UniqueAggregateNames | Rename one of the aggregates |
| ValidReferences | Available aggregates: ... |
| NoBidirectionalReferences | Remove reference from one side |
| NoSelfReferences | Use a value object or entity instead |
| CommandNaming | Try 'CreateFoo' or add to verbs.txt |
| ReservedNames | Rename to a non-keyword name |
| SafeIdentifierNames | Rename to PascalCase / snake_case |
| NoPiiInIdentity | Remove PII from identity_fields |
| ValidPolicyTriggers | Available commands: ... |
| GlossaryTermViolations | Replace with preferred term |

## More examples

**Bad command name:**
```
Command Data in Pizza doesn't start with a verb
  Fix: Try 'CreatePizzaData' or register 'Data' as a custom verb in verbs.txt
```

**Unknown reference:**
```
Order references unknown aggregate: Gadget
  Fix: Available aggregates: Pizza, Customer
```

**Bidirectional reference:**
```
Bidirectional reference between Pizza and Order
  Fix: Remove the reference from one side. Use a policy to react to changes on the other side
```

**Self reference:**
```
Widget references itself
  Fix: Use a value object or entity inside the aggregate instead of a self-reference
```
