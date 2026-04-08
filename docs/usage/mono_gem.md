# Mono-gem: Unified Source Tree

All Hecks framework code lives in a single `lib/` directory, organized by
chapter. One gem, many chapters.

## Usage

```ruby
# Gemfile
gem "hecks", path: "/path/to/hecks"

# Or from the command line:
ruby -Ilib examples/pizzas/pizzas.rb
```

## Directory layout

```
lib/
  hecks.rb              # main entry point
  bluebook.rb           # DSL kernel (tokenizer, IR, builders)
  hecks/
    chapters/           # chapter definitions
      bluebook.rb
      bluebook/         # paragraphs
      runtime.rb
      cli.rb
      workshop.rb
      ai.rb
      ...
    domain/             # Bluebook domain tools
    domain_model/       # IR node types
    dsl/                # DSL builders
    generators/         # code generators
    runtime/            # boot, configuration, ports
    workshop/           # interactive REPL
    ...
  hecks_cli/            # CLI commands and formatters
  hecks_ai/             # MCP server and AI tools
  hecksagon/            # hexagonal wiring DSL
  active_hecks/         # Rails integration
  go_hecks/             # Go target generators
  node_hecks/           # Node target generators
  hecks_static/         # Static Ruby target
```

## Chapter loading with base_dirs

When a chapter's implementation files span multiple subdirectories,
use `base_dirs:` instead of `base_dir:`:

```ruby
Hecks::Chapters.load_chapter(
  Hecks::Chapters::Bluebook,
  base_dirs: %w[hecks/domain hecks/dsl hecks/generators].map { |d| File.join(__dir__, d) }
)
```

This scopes the aggregate-to-file matching to avoid collisions with
files from other chapters.
