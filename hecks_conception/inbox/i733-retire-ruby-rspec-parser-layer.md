---
ref: i733
title: Retire the Ruby rspec parser layer toward behaviors + Rust parity
status: open
category: test-architecture
filed_by: miette
filed_at: 2026-05-23
---

# i733 — Specs should be behaviors against memory, not Ruby rspec

## Principle (Chris)
Specs should run against memory and be expressed as `.behaviors` (the
bluebook-native test format we already have), not imperative Ruby rspec.

## What triggered this
PR #687 (real SQLite persistence) made `:sqlite` a persistence kind. Two
Ruby rspec parser specs in `spec/hecksagon/dsl/hecksagon_builder_shell_adapter_spec.rb`
still asserted the pre-i67 behavior (`:sqlite` → io_adapters, persistence
nil) and failed CI on the merge. They were **deleted** rather than patched:
the routing is already covered cross-target by the Rust parser test
`routes_sqlite_adapter_into_persistence_with_db_option` + the parity suite
(62/62), so the Ruby rspec specs were a redundant legacy mirror.

## The work
- Audit the Ruby rspec suite (`spec/**/*.rb`). Two kinds:
  1. **Domain/command specs** → migrate to `.behaviors` (dispatch + expect,
     memory adapter). This is the bulk and the real win.
  2. **Parser/builder unit specs** (like the hecksagon_builder ones) → these
     mirror Rust parser `#[test]`s and are parity-enforced ; retire them as
     the Rust runtime + parity become authoritative, rather than maintaining
     two parsers' worth of unit tests.
- Goal end-state: CI's Ruby `rspec` step shrinks toward zero as coverage
  moves to `.behaviors` (memory) + the Rust suite ; the antibody already
  enforces this by blocking edits to `spec/*.rb`.
