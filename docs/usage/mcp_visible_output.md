# MCP Visible Output

Every MCP tool produces human-readable feedback visible in the Claude Code conversation.

## How It Works

MCP tools wrap AggregateHandle operations in `capture_output`, which captures the
same terse feedback the REPL prints. Claude and you see identical output.

## Example: Claude builds a blog domain

```
Claude calls: create_session("Blog")
→ "Blog session created"

Claude calls: add_aggregate("Post", attributes: [{name: "title", type: "String"}])
→ "title attribute added to Post"

Claude calls: add_lifecycle(aggregate: "Post", field: "status", default: "draft")
→ "lifecycle added to Post on status, default: draft"

Claude calls: add_transition(aggregate: "Post", command: "PublishPost", target: "published")
→ "PublishPost transition added -> published"

Claude calls: add_command(aggregate: "Post", name: "CreatePost", attributes: [{name: "title", type: "String"}])
→ "CreatePost command created on Post"

Claude calls: validate()
→ "Valid (1 aggregates, 1 commands, 1 events)"
```

## Available Tools

### Session
- `create_session` — start a new domain
- `load_domain` — load existing hecks_domain.rb

### Structure
- `add_aggregate` — create aggregate with optional attributes
- `add_attribute` — add attribute to existing aggregate
- `add_command` — add command with optional attributes
- `add_value_object` — add embedded value object
- `add_entity` — add sub-entity with identity
- `add_validation` — add field validation
- `add_policy` — add reactive policy (event → command)
- `add_lifecycle` — add state machine
- `add_transition` — add lifecycle transition
- `remove_aggregate` — remove aggregate

### Inspect
- `describe_domain` — full JSON model
- `list_aggregates` — aggregate names
- `preview_code` — generated Ruby source
- `show_dsl` — DSL source

### Build
- `validate` — check for errors
- `build_gem` — generate Ruby gem
- `save_dsl` — write hecks_domain.rb
- `serve_domain` — start HTTP server

### Play
- `enter_play_mode` — switch to live runtime
- `exit_play_mode` — back to build mode
- `execute_command` — run a command
- `list_commands` — available commands
- `show_history` — event timeline
- `reset_playground` — clear state
