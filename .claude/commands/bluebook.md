Write or modify Bluebook DSL definitions using the official DSL reference.

## Instructions

1. Read the DSL reference at `docs/usage/dsl_reference.md` for the complete syntax.

2. When adding domain concepts (aggregates, commands, policies, workflows, sagas), always use the Bluebook DSL — never hand-write Ruby implementations.

3. Key DSL patterns:

   - **Aggregates**: `aggregate "Name" do ... end`
   - **Commands**: `command "Name" do ... end` (inside aggregate)
   - **Policies**: `policy "Name" do; on "EventName"; trigger "CommandName"; end` (domain-level, reactive)
   - **Workflows**: `workflow "Name" do; step "CommandName"; end`
   - **Sagas**: `saga "Name" do; step "CommandName", on_success: "Event"; end`

4. Policies are the reactive hook mechanism — they listen for events and trigger commands:

```ruby
policy "NotifyKitchen" do
  on "PlacedOrder"
  trigger "PrepareIngredients"
  map pizza: :pizza, quantity: :servings
  condition { |event| event.quantity > 5 }
end
```

5. After modifying a `.bluebook` file, verify it parses:

```bash
ruby -Ilib -e "require 'hecks'; Hecks.boot('path/to/project')"
```

6. Update `docs/usage/dsl_reference.md` if you add new DSL keywords.
