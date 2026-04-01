# `hecks build --gem` — Produce a Publishable Domain Gem

The `--gem` flag tells `hecks build` to run `gem build` on the generated
output after code generation completes, producing a `.gem` artifact ready
for `gem push` or local installation.

## Usage

```bash
# Build the domain gem and package it
hecks build --gem

# Combine with static target
hecks build --static --gem
```

## What Happens

1. `hecks build` generates the domain gem as usual (gemspec, lib layout,
   ports, adapters, specs, docs).
2. With `--gem`, it then runs `gem build <name>.gemspec` inside the
   generated directory.
3. The resulting `.gem` file appears in the generated gem root directory.

## Example

```bash
$ hecks build --gem
Built pizzas_domain v2026.04.01.1
  Docs: ./pizzas_domain/docs/
  Output: ./pizzas_domain/
Packaging gem...
Gem artifact: ./pizzas_domain/pizzas_domain-2026.04.01.1.gem

$ ls ./pizzas_domain/*.gem
./pizzas_domain/pizzas_domain-2026.04.01.1.gem

$ gem push ./pizzas_domain/pizzas_domain-2026.04.01.1.gem
```

## Supported Targets

The `--gem` flag works with the `ruby` (default) and `static` targets.
Other targets (go, node, rails) print a warning and skip gem packaging.

```bash
$ hecks build --target go --gem
Built Pizzas Go project
  Output: ./pizzas_go/
--gem is only supported for ruby and static targets
```
