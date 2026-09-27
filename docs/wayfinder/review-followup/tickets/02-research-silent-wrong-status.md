---
type: research
status: closed
blocked_by: []
claimed_by:
---

# Research: are the two silent-wrong bugs still live on main

## Question

Two defects are documented as silent-wrong: `group_by` on the memory adapter keeps only the
first row when several share a key, and a `compute` with a dotted source never fires in
compiled SQL on PostgresEra (the migration succeeds and the record keeps its old value).
Reproduce each against current `main`, name the code that decides the behavior, and list every
place the docs or ADRs state the limitation (ADR 0061, README project status). Facts only; the
decision is in *Silent-wrong bugs*.

## Answer

Both defects still reproduce on this checkout, and neither is refused at boot or seal time.
The only refusal is the opt-in `--profile client` model check.

**`group_by` row drop (reproduced by running).** Rows `w1` and `w2` share group `g1`; the
result keeps `w1` and `w2` is gone, with no error. Correction to the review: this is not
specific to the memory adapter. `lib/hecks/runtime/read_model_interpreter.rb:279-290` (`nest`,
the `stripped.first` at line 288) runs whichever adapter supplied the rows, because a
`group_by` model never takes the native path. ADR 0061 says the Rust `nest` does the same.
Seal time (`read_model_builder.rb:355-365`, `read_model_interpreter.rb:244-266`) only checks
shape and that the field exists. Grouping by the aggregate's whole identity cannot collide.
Opt-in refusal: `client_group_by_row_drop` in `model_check/client_profile.rb:60-71`.

**Dotted-source `compute` (reproduced against a local Postgres).** The repo's own pending
example (`spec/adapters/driven/postgres_era/migration_data_safety_spec.rb:443`) mints
successfully and leaves `price.cents` at `1250`. Dotted destinations work (control example at
`:404`). Cause: `ports/persistence/plugins/era/translation/rule_compiler.rb:131-140`
(`compile_compute`) tests `__s ? 'price.cents'`, which asks for a top-level key literally named
`price.cents`, so the `ELSE __s` branch returns the state unchanged. Lines 135 and 139 repeat
the mistake; only the destination goes through `path_literal`. The translation judge
(`meta_validator/translation_judge.rb:152-158`) passes `from` through unchecked, and there is no
Ruby-side fallback (`lineage.rb:132-135`). Opt-in refusal: `client_dotted_compute_source`
(`client_profile.rb:105-116`), which needs the registry's `translations:` passed in.

**Where the limitation is documented.** `README.md:610-615` and `:623-626` (the first
wrongly says "on the in-memory adapter"), ADR 0061 (`:45-66`, `:121`, `:341`), `CHANGELOG.md`,
`docs/future-features.md`, `docs/implemented/guides/verification.md`. There is no ADR for the
dotted-compute defect, and `docs/implemented/reference/read_model.md` does not mention the
`group_by` limit.

**Guards already in place.** Each defect has a retire-with-the-bug probe in
`spec/model_check_client_profile_spec.rb` (`:261`, `:270`) and the pending example turns red
when the bug is fixed. Nothing is on by default.
