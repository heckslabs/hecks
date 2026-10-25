# The library

```ruby skip
lib/hecks/
  language/     the language, declared in its own bluebooks.  WHAT A BLUEBOOK IS.
  grammar/      the expression and translation sublanguages, and the Admit gate.
  bluebook/     dsl → ir → expression.  READING ONE.
  runtime/      dispatch, instances, the registry.  RUNNING IT.
  adapters/     driven adapters — persistence, authentication, clock, identity, and the rest (lib/hecks/adapters/driven/).
  ports/persistence/plugins/era/  domain-version translation — eras and lineage.
  projector/    IR serialization — the translation-edge digest reads it.

  adapters/driving/   the driving adapters (Ruby, CLI, MCP, JSON, webhook).  Class-free, per boot.
  router/               project-wide dispatch; installs each chapter's namespace at boot.
  ports/                domain ports — auth, identity, persistence, query.
  query_specification/  a query's shape, held apart from any engine that answers it.
  projections/          IR as a capability — emits_ir and its consumers (OIDC, reference, parser table).
  forms/                IR → HTML, content-negotiated against plain JSON.
  fuzzing/              generated sequences, checked against declared properties.
  doc/                  the generated DSL reference (hecks language_run.project_reference).
  framework/            shared, domain-agnostic bluebooks — e.g. Governance, Identity, Privacy.
  deploy/               the Deploy bluebook — what deployed_to means.
```

Domain-version translation (eras and lineage) lives under `language/translation/`. This
map names the main layers only; `ls lib/hecks` is the full list.

The split follows the dependency direction, not the topic: the
expression evaluator lives in the semantic core, not `projector/`,
because the runtime evaluates every `given` and invariant through it
directly. Nothing here is required by `require "hecks"` unless a
booted domain uses it — `forms/` and `fuzzing/` stay out of the core
boot chain, so a project that never touches one never pays for it.

## The second runtime

```ruby skip
rust/
  src/kernel/     the hand-written interpreter — walks given/ensures/mutation data, same job as CommandInterpreter#call in Ruby.
  host/           the production HTTP host (hand-written): serves the domain's WASI module over Postgres, mints eras. See implemented/rust-host.md.
  lsp/            the language server.
  build/          the Rust build tooling the build commands call.
  src/generated/  typed structs and enums per domain, written by hecks build.project_rust — never hand-edited.
  parser/         a generated Rust parser, built from the language's own Syntax chapter (hecks language_run.project_parser_table).
  codegen/        the Rust code generator itself, driven from canonical IR; hecks build.project_rust builds the IR from the live registry and runs it.
  web/            the wasm-bindgen crate hecks build.build_browser_wasm builds — a separate cdylib from the WASI binary.
```

`rust/src/kernel/` and `rust/host/` are written by hand — everything
else (`generated/`, the parser tables, the type shapes) is projected
from the same canonical IR the Ruby runtime reads. See [Projections: Rust and
WebAssembly](implemented/guides/projections.md) for what
that buys, and [Running a
runtime](implemented/guides/running-a-runtime.md) for the
field-by-field contract a third dispatch runtime would need.
