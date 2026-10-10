# RuboCop runs at its defaults, with a short list of deliberate overrides

**Status:** Proposed. Date: 2026-10-05. `.rubocop.yml` names the cops this codebase departs from RuboCop on, each with its reason, and everything else runs at the default. Every offense the defaults find is fixed, so there is no todo file.

## Context

The previous `.rubocop.yml` was tuned to the codebase's own established style: it disabled or loosened cops until the tree was clean, and tolerated the rest of the offenses in a per-file todo. A cop that was off said nothing about whether its default was wrong for this code or only inconvenient to satisfy, so a reader could not tell a convention from a convenience, and a new file was held to a lower bar than RuboCop's own.

The reverse is a configuration that is the defaults plus a short, argued list. Each departure then states a decision, and a cop that is not on the list is one nobody has decided against.

## Decision

1. **Every cop runs at its RuboCop default unless `.rubocop.yml` overrides it, and every override carries its reason in a comment beside it.**
2. **House style overrides**, where the codebase's convention is the point:
   - Double quotes everywhere, including inside interpolation (`Style/StringLiterals`, `Style/StringLiteralsInInterpolation`).
   - Table alignment for hash rockets and colons (`Layout/HashAlignment`), so a column of pairs reads as a table.
   - 130 columns for code, with comment lines exempt (`Layout/LineLength`): the comment linter owns comment length at 100 columns.
   - No `frozen_string_literal` comment (`Style/FrozenStringLiteralComment` off): one file opts in, and enforcing it everywhere would be churn with no bug behind it.
   - Explicit quoted arrays, not `%w` or `%i` (`Style/WordArray`, `Style/SymbolArray` off).
3. **Structural overrides**, where the cop's premise does not hold for this code:
   - `Style/ModuleFunction`: `module_function` is deliberate, so a tool is called as `Hecks::QueryIR.constructs(...)` and never instantiated.
   - `Style/OpenStructUse`: Struct-based value types are deliberate.
   - `Security/Eval`: a `.bluebook` file is a Ruby DSL script, so evaluating committed sources and spec fixtures is the gem's job and not an untrusted-input hazard.
   - `Lint/UnusedMethodArgument` with `AllowUnusedKeywordArguments`: persistence and query adapters share one keyword signature, so an adapter may ignore a keyword, and renaming it would break callers that pass it by name.
   - `RSpec/DescribeClass`: many specs describe a word, a behavior or a domain scenario, not one Ruby class.
   - `RSpec/SpecFilePathFormat`: specs are not one file per class mirroring `lib/`; there is no `hecks/` prefix, large classes have one file per concern, and directory names are shorter than the namespace.
   - `RSpec/BeforeAfterAll`: the suite has no transactional rollback to lose, and `before(:context)` boots Postgres, cargo or a deploy dry-run once per file instead of once per example.
   - `RSpec/InstanceVariable`: `let` would rerun that setup per example, or skip unconditional `before` side effects that examples depend on without naming the value.
   - `Lint/ConstantDefinitionInBlock` and `RSpec/LeakyConstantDeclaration`: spec constants are file-local fixtures, `spec/load_hygiene_spec.rb` fails on colliding names across files, and `stub_const` does not fit a fixture with no prior value.
4. **Every offense the defaults find is fixed, in one change, and there is no `.rubocop_todo.yml`.** The configuration is the defaults and the list above and nothing else, so `bundle exec rubocop -c .rubocop.yml` is clean with no file excluded.
5. **A cop is excluded for a file only by an override on the list**, with its reason; an offense is never parked in a per-file exclusion list.
6. **Paths that are not hand-written source are not inspected** (`AllCops` `Exclude`): `rust/`, `vendor/`, generated Ruby files whose generator is the thing to lint, the comment sweep kit, and `tmp/`. `tmp/` is gitignored scratch that never ships and is absent from CI and from a clean checkout, so an untracked probe there must not fail the gate on one machine.
7. **Some cops are fixed by hand, not autocorrected.** Autocorrecting these once changed behavior: `Style/CombinableLoops`, `RSpec/ScatteredSetup`, `Lint/UnusedBlockArgument`, `Style/SoleNestedConditional`, `Style/IfInsideElse`, `Style/Next` and `Style/GuardClause`. Each rewrite moves code across a control-flow, ordering or scope boundary, so a person reads the result. The mechanical cops may be autocorrected, and the full suite runs before the change is let through.

## Consequences

- A reader can tell a convention from a convenience: a cop on the override list is a decision, and any other cop is RuboCop's.
- All code, new and old, is held to the defaults, so the gate is `rubocop` clean and nothing more.
- Raising a cop's limit to clear an offense is a change to the override list, and needs a reason there.
- A new RuboCop release can add cops. Those run at their defaults, and a new offense must be fixed or, if the cop does not suit the code, named in the override list with its reason.

## Alternatives considered

- **Keep the tuned configuration and add cops to it as they matter.** Rejected: it leaves the question of which disabled cops were decisions unanswered.
- **A per-file todo that only shrinks.** Rejected: it leaves a second list of tolerated offenses beside the override list, and a regenerated todo hides new offenses.
- **Autocorrect everything once.** Rejected for the cops in decision 7, which changed behavior when autocorrected.

