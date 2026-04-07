# Autophagy: Self-Hosting Compiler (Hecks v0)

Hecks compiles itself into a single dependency-free Ruby script. The pipeline
uses Prism AST analysis to build a file-level dependency graph, topologically
sorts it, and concatenates all source into one file. No gems, no bundler,
no require infrastructure — just `ruby hecks_v0`.

## Quick Start

```bash
# Compile Hecks into a binary
hecks compile

# Run the binary
./hecks_v0 version
./hecks_v0 boot examples/pizzas
./hecks_v0 self-test

# Debug compilation with trace output
hecks compile --trace
```

## CLI Options

```bash
# Default output: ./hecks_v0
hecks compile

# Custom output name
hecks compile --output my_hecks

# Trace mode — emits [AUTOPHAGY] decisions to stderr
hecks compile --trace

# Show what would be compiled (no file written)
hecks compile --plan
```

## Build Target

The binary compiler is also available as a build target:

```bash
hecks build --target binary
```

## Programmatic Usage

```ruby
require "hecks"
require "hecks/compiler"

# Compile to a binary
compiler = Hecks::Compiler::BinaryCompiler.new
compiler.compile(output: "hecks_v0")

# Compile with trace output
compiler.compile(output: "hecks_v0", trace: true)
```

## How It Works

The compiler pipeline has five stages:

1. **Prism AST Analysis** (`SourceAnalyzer`) — discovers all `.rb` files under
   `lib/`, parses each with Prism, and extracts constant definitions, references,
   inheritance, mixins, and namespace scopes
2. **Dependency Graph** (`DependencyGraph` + `ConstantResolver`) — builds
   file-level edges from constant references. Two resolution layers:
   - Layer 1: Prism AST (direct constant refs, superclass, include/extend)
   - Layer 2: Bluebook IR (method-call deps like `Hecks.describe_extension`)
3. **Topological Sort** — Kahn's algorithm with `CycleSorter` for cycles.
   Wiring files (`foo.rb` with `foo/` directory) load after their children
4. **Source Transform** (`SourceTransformer`) — strips all require/autoload
   calls and expands compact class syntax (`class Hecks::Foo::Bar` → nested
   `module Hecks; module Foo; class Bar`)
5. **Bundle Write** (`BundleWriter`) — concatenates transformed source with
   forward declarations, stdlib requires, and a CLI entrypoint

## Trace Mode

The `--trace` flag emits every compiler decision to stderr:

```
[AUTOPHAGY] EDGE hecks/dsl/domain_builder.rb → hecks/dsl/aggregate_builder.rb (ref: AggregateBuilder)
[AUTOPHAGY] EDGE hecks/runtime.rb → hecks/ports/commands.rb (method)
[AUTOPHAGY] EDGE hecks/conventions.rb → hecks/conventions/naming.rb (wiring)
[AUTOPHAGY] CYCLE: hecks/foo.rb, hecks/bar.rb
```

## Self-Hosting Verification

```bash
# Compile Hecks using interpreted Hecks
ruby -Ilib -e 'require "hecks"; require "hecks/compiler"; Hecks::Compiler::BinaryCompiler.new.compile(output: "hecks_v0")'

# Run v0 on the pizzas example
./hecks_v0 boot examples/pizzas

# Check v0 self-test (modules, targets, status)
./hecks_v0 self-test
```
