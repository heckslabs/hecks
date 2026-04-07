# Self-Hosting: Hecks Generating Itself

Hecks describes itself using its own DSL (Bluebook chapters). The self-hosting
tools compare what generators *would* produce against what actually exists,
quantifying the gap between "described" and "generated."

## Two Modes

### Domain Mode (default)
Uses `DomainGemGenerator` — produces user-domain code patterns (aggregates as
data classes, commands, events, ports, adapters). Shows what a *user* domain gem
would look like if generated from the chapter IR.

### Framework Mode (`--framework`)
Uses `FrameworkGemGenerator` — locates actual files by aggregate name, generates
skeletons with correct module nesting, doc comments from descriptions, and method
stubs from commands. Shows how much of the *framework* code is IR-derivable.

## CLI Usage

```bash
# Domain mode — what standard generators would produce
hecks self_diff hecksagon

# Framework mode — skeleton comparison against actual code
hecks self_diff hecksagon --framework

# Available chapters: hecksagon, bluebook, runtime, workshop, targets,
#                     cli, extensions, ai, rails
hecks self_diff
```

## Programmatic Usage

```ruby
require "hecks"
require "hecks/chapters/hecksagon"

domain = Hecks::Chapters::Hecksagon.definition

# Framework mode
diff = Hecks::Generators::Infrastructure::SelfHostDiff.new(
  domain, gem_root: "hecksagon", mode: :framework
)
report = diff.summary
puts "Coverage: #{((report[:match] + report[:partial]) * 100.0 / report[:total]).round(1)}%"

# Inspect what files are located
gen = Hecks::Generators::Infrastructure::FrameworkGemGenerator.new(
  domain, gem_root: "hecksagon"
)
gen.located_aggregates.each { |l| puts "#{l[:aggregate]} → #{l[:path]}" }
gen.unlocated_aggregates.each { |name| puts "UNLOCATED: #{name}" }
```

## Status Classifications

| Status | Meaning |
|--------|---------|
| **match** | Generated file is identical to actual file |
| **partial** | Both exist but content differs (shows % line overlap) |
| **uncovered** | File exists in gem but no generator produces it |
| **extra** | Generator would produce this but gem doesn't have it |

## DSL Extensions for Self-Hosting

These DSL methods enrich the chapter IR so generators can produce more
accurate skeletons:

```ruby
b.aggregate "SqlAdapterGenerator" do
  description "Generates Sequel-based repository adapter classes"
  namespace "Hecks::Generators::SQL"     # module nesting
  inherits "Hecks::Generator"            # superclass
  includes "SqlBuilder"                  # mixin
  command "Generate"
end

b.aggregate "SqlBuilder" do
  description "Mixin with Sequel-based generation helpers"
  namespace "Hecks::Generators::SQL"
  command("BuildInsert") { method_name "insert_lines" }  # override method name
end

b.entry_point "hecks_persist"  # autoload entry point file
```

The skeleton generator determines whether to emit `class` or `module` from the
IR: aggregates with `inherits` or `includes` produce classes, others produce modules.

## Hecksagon Baseline

```
Framework mode: 93.3% coverage (28/30 files partial, 2 uncovered)
Domain mode:    0.0%  coverage (31 uncovered, 142 extra)
```

The gap between modes shows exactly what `FrameworkGemGenerator` adds:
it recognizes the actual file structure and generates skeletons that share
class names, method names, and doc comments with the real code.

## What the Gap Means

- **uncovered** files need new generator types or need to be modeled as aggregates
- **partial** files have IR-derivable structure (class/method signatures) but
  hand-written implementation bodies — these are candidates for the slot system
- **extra** files are standard domain patterns that don't apply to framework gems
- **match** files are fully self-hosted
