## What and why

<!-- What changed, and the reasoning — the "why" a comment would carry
     in this codebase (see Gemfile, .rubocop.yml, .githooks/pre-push for
     the house style). Link an issue if there is one. -->

## Checklist

- [ ] `bundle exec rspec` passes
- [ ] `bundle exec rubocop -c .rubocop.yml` is clean
- [ ] Touched a `.bluebook`, the DSL builder, the runtime, or the IR? →
      `bin/model_check` and `bin/fuzz` are clean
- [ ] Added or changed a DSL keyword/argument? → `bin/doc_coverage` is
      clean, and `docs/implemented/reference/` has real prose (not the
      `TODO` sentinel) with a runnable example
- [ ] Edited a `ruby`-fenced example in the README or `docs/implemented/guides/`?
      → `bundle exec rspec spec/guides_spec.rb` passes
- [ ] Deliberately changed the builder's IR shape? → regenerated the
      golden IR with `GOLDEN=rewrite bundle exec rspec spec/ir_golden_spec.rb`
      and read the diff

## Anything not covered above

<!-- e.g. touches rust/project/*.rb and you ran the Rust build/coverage
     tools locally, or this is docs-only and none of the above applies. -->
