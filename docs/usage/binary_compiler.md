# Binary Compiler (Hecks v0)

Compile the entire Hecks framework into a single self-contained Ruby script.
The output binary boots Hecks with zero `require_relative` -- all 400+ source
files are concatenated in load order.

## Quick Start

```bash
# Compile Hecks into a binary
hecks compile

# Run the binary
./hecks_v0 version
./hecks_v0 boot examples/pizzas
./hecks_v0 self-test
```

## CLI Options

```bash
# Default output: ./hecks_v0
hecks compile

# Custom output name
hecks compile --output my_hecks

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

# Check compilation plan
plan = compiler.plan
puts "Files: #{plan[:file_count]}"
plan[:files].each { |f| puts "  #{f}" }
```

## How It Works

1. **Source Collection** -- introspects `$LOADED_FEATURES` after requiring
   `hecks` and booting a domain, capturing all source files in load order
2. **Forward Declarations** -- injects module stubs for load-order
   dependencies (e.g., `HecksDeprecations`) and extends registry methods
3. **Line Stripping** -- comments out `require_relative`, internal `require`,
   `Chapters.load_chapter/load_aggregates` calls, and `Dir[]` glob requires
4. **Feature Registration** -- pre-registers all bundled file paths in
   `$LOADED_FEATURES` so Ruby's `require` skips them
5. **Entrypoint** -- appends a CLI dispatcher for `boot`, `version`, and
   `self-test` commands

## Self-Hosting Verification

```bash
# Compile Hecks using interpreted Hecks
ruby -Ilib -e 'require "hecks"; require "hecks/compiler"; Hecks::Compiler::BinaryCompiler.new.compile(output: "hecks_v0")'

# Run v0 on the pizzas example
./hecks_v0 boot examples/pizzas

# Check v0 self-test
./hecks_v0 self-test
```
