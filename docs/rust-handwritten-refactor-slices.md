# Rust hand-written surface — module refactor slice plan

Trigger: `rust/parser/src/parse/mod.rs` had grown to 1196 lines. Investigating it surfaced the
same shape of problem (big hand-written files with real internal seams, organized the old
`foo/mod.rs` way) across the rest of the hand-written Rust surface — `rust/parser/`, `rust/src/`,
`rust/host/`, `rust/codegen/`, `rust/build/`. This plan covers all of it. Generated files
(`rust/src/generated/**`, `rust/parser/src/keywords.rs`, `rust/host/src/field_hints.rs`,
`rust/src/kernel/{attribute_shapes,expression_operators}/mod.rs`, `rust/src/kernel/refusal_wording.rs`)
are **out of scope** — they're regenerated from the bluebook grammar, not hand-refactored.
`rust/parser/src/build/` is also out of scope — it already mirrors the Ruby DSL builders 1:1,
which is what this refactor is trying to achieve elsewhere.

**Verified against `main` @ `9cc5ef33`** (post S5/S8/S3 of the DSL-slices arc). Those three
commits touched `parse/mod.rs`, `emit.rs`, `ir.rs`, `lex.rs`, `auth.rs`, `codegen/{commands,
mutations}.rs` — checked diff-by-diff against every boundary below; every change landed either as
a `then_set`→`sets` comment rename or as real logic that stayed entirely inside one already-planned
bucket (S3 even added a new function, `positional_symbol_text`, that lands exactly in
`identified_by.rs` next to its sibling `parse_identified_by`). **Module boundaries below are
current; exact line numbers are not** — they were accurate at read time and will keep drifting
under concurrent work, so locate functions by name/grep when executing a slice, not by trusting a
cited line range literally. **Run further concurrent work in an isolated worktree** — an earlier
version of this same doc was lost mid-session to an untracked-file wipe from a second session
sharing this checkout (matches the prior `project_reaction_defect_isolation` lesson). This copy is
committed immediately after being written, specifically so that can't happen again.

## Governing principles (settled, apply uniformly — do not relitigate)

1. **Modern Rust module convention.** A `foo.rs` sibling file + `foo/` directory of submodules,
   never `foo/mod.rs`. Recurse as deep as real size/cohesion warrants — not for its own sake.
2. **Names say exactly what's inside.** No vague buckets (`utils.rs`, `helpers.rs`). If a
   module's path already conveys context, a function inside it doesn't repeat that context in
   its own name (`gates::word::gate()`, not `gates::word::word_gate()`).
3. **Split along the code's own real seams**, verified by actually reading the file and its call
   graph — not by line-count alone, and not by forcing a Ruby correspondence. The one exception:
   `rust/codegen/` is an explicit, acknowledged port of `rust/project/*.rb`, so for files in that
   crate specifically, matching the Ruby source's own internal organization is a real signal.
   Everywhere else (parser gates/lexing, `rust/host`, `rust/build`), there is no Ruby analog —
   Rust-native seams only.
4. **Mechanism over call site.** A helper used by only one caller is not automatically part of
   that caller's concern — ask what the helper *does*, not just who calls it (this reversed an
   initial instinct twice: `lex.rs`'s opener-detection cluster, `ruby_value.rs`'s `split_items`).
5. **Delete confirmed-dead code; never relocate it.** "Confirmed" means grepped across the
   *entire* `rust/` tree, not just the crate or file — a stale doc comment nearly caused a real
   miss here (`next_line`/`GatedLine` were almost deleted alongside genuinely-dead
   `walk_body`/`handle_call` because a comment lumped them together; grep proved otherwise).
6. **No re-export shims.** When a symbol moves, every call site is updated to the new qualified
   path. Nothing keeps the old name alive "for compatibility."
7. **A file that's just long, not muddled, doesn't get split.** Several files below (`ir.rs`,
   `dispatch.rs`, `lambda_client.rs`, six of seven `rust/codegen/` files, `lineage_pass.rs`) were
   deliberately left alone after inspection — say so plainly rather than forcing a cut.

## Target tree

```
rust/parser/src/
  parse.rs                    # was parse/mod.rs — pub mod decls + shared imports only
  parse/
    aggregate.rs, entity.rs, command.rs, query.rs, policy.rs,        # unchanged
    process_manager.rs, read_model.rs, value_object.rs, lifecycle.rs,
    domain_port.rs, hecksagon.rs, chapter.rs, file.rs
    gates.rs                  # pub mod word; pub mod body; pub mod argument; + next_line + GatedLine
    gates/
      word.rs                 # fn gate(...)       [was word_gate]
      body.rs                 # fn gate(...)       [was body_gate]
      argument.rs             # fn gate(...) + as_named + validate_named   [was argument_gate]
      argument/
        pairs.rs               # fields_pairs, named_pairs, has_top_level_rocket,
                                # split_top_level_rocket, rocket_key_name
    lexical.rs                 # classify_lexical_kind, kind_matches, type_context_call_word,
                                # is_number_token, symbol_text
    argument_values.rs         # positional_raw (private), positional_text, positional_symbol,
                                # positional_constant, named_raw, named_symbol, named_text, named_flag
    identified_by.rs           # PendingIdentity (Type/Fields/Paths), parse_identified_by,
                                # positional_symbol_text, paths_from_source
    attribute.rs                # build_attribute, resolve_type_expression
    nested_body.rs              # source_body_text, parse_nested_body, brace_body_statements
    not_implemented.rs          # dispatch_stub, not_built_yet
    # walk_body/handle_call: DELETED (confirmed dead, zero external callers) — no walk.rs file

  lex.rs                      # was lex.rs monolith — thin: pub struct SourceLine<'a> +
                               # pub mod text; pub mod shape; pub mod do_block; pub mod receiver;
  lex/
    text.rs                   # lines, join_continuations, strip_comment, ends_outside_quotes,
                               # ends_with_bare_backslash, ends_with_bare_comma, bracket_delta,
                               # split_items (moved in from ruby_value.rs)
    shape.rs                  # Opener, Call, LineShape, FORBIDDEN_LEADING_WORDS,
                               # FILE_RECEIVER_PREFIX, classify, leading_identifier_end,
                               # find_top_level_assignment, strip_balanced_parens; pub mod opener;
    shape/
      opener.rs                # split_opener, trailing_do, find_top_level_brace,
                                # is_hash_literal_brace, matching_brace_body
    do_block.rs                 # capture_body [was capture_do_block_body], opens_a_do_block
    receiver.rs                 # strip [was strip_aggregate_receiver]

  emit.rs                     # was emit.rs monolith — thin: pub enum JsonValue + private impl +
                               # pub mod writer; pub mod ir_to_json;
  emit/
    writer.rs                  # write, indent, write_value, write_string, write_array, write_object
    ir_to_json.rs               # bluebook_json, canonical_form_table, aggregate_json ...
                                 # port_operation_json, ruby_value_json (all *_json fns, incl.
                                 # query_options_json — shrank under S3, still belongs here)

  ruby_value.rs                # was ruby_value.rs monolith — thin: pub enum Value +
                                # pub mod to_source; pub mod from_source;
  ruby_value/
    to_source.rs                # render, format_ruby_float, quote, to_s
    from_source.rs              # read, unquote_for_symbol, is_integer, is_float, is_quoted,
                                 # is_single_quoted, unquote_single, unescape_single_quoted_inner,
                                 # unquote, unescape_double_quoted_inner, scan_adjacent_strings,
                                 # read_hash, read_array

  ir.rs                        # UNCHANGED — one coherent wire-format data graph, no logic seams
                                # (shrank further under S3 — ConsistencySpec/FreshnessSpec/
                                # IndexHint deleted — reinforces the no-split call, doesn't change it)

rust/src/
  kernel.rs                    # was kernel/mod.rs — pure rename, content (Event, MutationRecord,
                                # Refusal's Display impl) stays inline, zero call-site changes
  kernel/                      # 15 existing submodules, unchanged

rust/host/src/
  auth.rs                      # thin: mod token; mod oauth; mod session; mod member;
  auth/
    token.rs                    # now_secs, sign, verify_sig, hex_encode, B64, base64_encode,
                                 # base64_decode
    oauth.rs                    # ISSUER, STATE_TTL_SECS, Claims, authorization_url, verify_state,
                                 # verify, verify_id_token, urlencode
    session.rs                  # Session, session_cookie, parse_session_cookie
    member.rs                   # resolve_identity, member_row_by_email, member_rows,
                                 # append_member_state, session_for_member_by_identity, provision,
                                 # grant_access, all_people, holds_admin, httpdate_now,
                                 # civil_from_days

  web.rs                       # thin-ish: render (sole external entry point, unchanged),
                                # route, extract_cookies, session_secret/redirect_uri, home_body
  web/
    login_routes.rs             # UNGATED_PATHS, auth_route, is_admin, google_callback,
                                 # ERROR_MESSAGES, login_page, admin_members_page
    ir_lookup.rs                 # find_aggregate, find_command, find_value_object, agg_name,
                                  # identity_paths
    field_shape.rs                # Field, FieldKind, humanize, PRIMITIVES, resolve_field,
                                   # reference_target, value_object_shape,
                                   # cross_aggregate_value_object, closed_set_members,
                                   # select_or_radio, admitted_field, value_object_field,
                                   # money_shaped, money_field, primitive_field, text_field,
                                   # text_html_type, text_kind, command_fields
                                   # + the existing field-hint test module
    params.rs                     # extract_args, collect_field, cast_scalar, nest
    crud_routes.rs                 # aggregate_index, record_show, command_route, submit,
                                    # instances_for, with_id
    form_render.rs                 # form_body, render_field
    encoding.rs                    # parse_form, percent_decode, base64_decode, B64, split_format
    response.rs                    # esc, page, html, redirect, redirect_with_cookie, respond

  journal.rs                    # thin: pub mod replay; pub mod naming; pub mod lineage;
  journal/
    replay.rs                    # ensure_schema, record_dead_letter, load_steps,
                                  # load_steps_after, Snapshot, load_snapshot, append,
                                  # save_snapshot, SagaRow, load_sagas, save_saga, delete_saga
    naming.rs                     # snake, acronym_boundary, word_boundary, quote_ident
    lineage.rs                    # LineageConfig, storage_name, journal_table,
                                   # head_snapshot_table, current_era, Mutation,
                                   # append_lineage_mutation, head_view, read_lineage_head_all,
                                   # read_lineage_head_by_id + the existing lineage_tests module

  dispatch.rs                   # UNCHANGED — one algorithm (seed→replay→persist) + its own
                                 # ~730-line integration test suite; no second concern to extract
  lambda_client.rs              # UNCHANGED — trait/adapter pipeline already coherent;
                                 # AwsLambdaInvoker → aws_invoker.rs is a documented FUTURE option
                                 # (Cargo feature-gating the AWS SDK dep), not part of this pass

rust/codegen/src/
  commands.rs, json_codec.rs, mutations.rs, registry.rs,             # UNCHANGED — all six mirror
  domain_generator.rs, queries.rs                                    # one flat Ruby module 1:1

  json.rs                       # was json.rs monolith — thin: pub enum Json + impl (parse
                                 # delegates to parser::parse) + Display + format_number +
                                 # pub mod parser;
  json/
    parser.rs                    # Parser struct + impl, pub(super) fn parse(text) -> ...

rust/build/src/
  lineage_pass.rs                # UNCHANGED — one 3-phase pass, matches this crate's own
                                  # convention (resolve.rs/sidecars.rs also keep helpers inline)

  json.rs                        # was json.rs monolith — thin: pub enum Json + impl
                                  # (get/get_mut/as_str/as_array/as_array_mut/as_object/as_bool/
                                  # each/set_bool/set, parse delegates) + pub mod parser; pub mod writer;
  json/
    parser.rs                     # Parser struct + impl, pub(super) fn parse(text) -> ...
    writer.rs                     # write, indent, write_value, write_string, write_array, write_object
```

## Confirmed dead code (delete, don't relocate)

- `rust/parser/src/parse/mod.rs`: `walk_body`, `handle_call`, and the doc-comment prose
  describing them — zero external callers anywhere in `rust/` (grep-confirmed). `next_line` and
  `GatedLine`, referenced by the same paragraph, are **not** dead (12+ call sites across
  `parse/*.rs`) — they move live into `gates.rs`, do not delete.
- `rust/codegen/src/json.rs`: `Json::as_f64`, `Json::as_i64` — confirmed dead; the only grep hits
  are a string table that emits these method *names* into generated Rust source text, not calls
  to this file's own methods.

## Flagged for a compiler-verified check before deleting (not blocking this plan)

- `rust/codegen/src/json.rs`: `impl fmt::Display for Json` — no call site found by grep, but
  `Display` impls can be picked up by generic bounds a plain grep won't catch. Run
  `cargo build` with dead-code warnings on the finished refactor and delete if confirmed unused.
- `rust/build/src/json.rs`: `Json::as_array` — no caller found (`as_array_mut` is used
  exclusively), but it may be deliberate symmetry with `as_array_mut`/`as_object`/`as_str`. Same
  treatment: verify via compiler warning, then a human call on keep-for-symmetry vs. delete.

## Out of scope for this pass (noted so it isn't silently lost)

- `rust/host/src/lambda_client.rs`: extracting `AwsLambdaInvoker` into `lambda_client/aws_invoker.rs`
  is a real, documented future seam (only if the crate wants to feature-gate the AWS SDK
  dependency) — not a readability problem today.
- `rust/codegen/src/domain_generator.rs`, `prelude.rs`, `main.rs`: `puts_str`/`puts_blank` are
  triplicated verbatim across all three files. Worth deduping into `shared.rs` (already this
  crate's home for one other small cross-file helper) — low-risk, but it's a duplication cleanup,
  not a module-boundary question, so it's a separate small slice if wanted, not bundled here.
- `rust/codegen/src/registry.rs`: `EntityCommandEntry.entity_name`/`.entity_identity_reading` are
  write-only (set by `domain_generator.rs`, never read) — already self-documented in the struct's
  own comment as deliberate shape-parity with Ruby, not a bug. FYI only.
- `rust/codegen/src/mutations.rs`: `Transition` doesn't carry Ruby's `unconstrained` field — a
  parity gap, unrelated to module boundaries.
- Visibility hygiene: several `pub fn`/`pub struct` items in `rust/codegen/src/` are reachable
  only from within their own file (candidates for `pub` → `pub(crate)`/private tightening).
  Orthogonal to this plan.
- `rust/build/src/lineage_pass.rs`'s `snake_case` duplicates `rust/codegen/src/hecksagain_naming.rs`'s
  `snake` — unavoidable, since `build` and `codegen` are separate standalone bin crates with no
  shared lib target. Not an action item.

## Execution: slices for subagents

Crates are fully independent of each other (five separate `Cargo.toml`s, no shared files) — the
five per-crate integration slices in Wave 1 can all run **in parallel with each other**. Within a
crate, creation slices (Wave 0) only ever *write new files*, never touch the existing monolith, so
they can run in parallel too. Each crate's *integration* slice is the one place many existing
files get touched at once (the old monolith shrinks/deletes, every external call site updates) —
that step is single-owner per crate, not further parallelized, for the same reason `parse/mod.rs`'s
own integration wasn't split up: it's where everything gets stitched together and merge conflicts
would just recreate the problem this plan exists to avoid.

**Run execution in an isolated worktree** (`isolation: "worktree"` on the Agent/Workflow calls, or
a manually created `git worktree`), not the shared main checkout — see the note at the top of this
doc for why.

### Wave 0 — parallel, additive-only (create new files; do not edit the file being split)

| Slice | Crate | Creates |
|---|---|---|
| S-K | `rust/src` | `kernel.rs` (rename of `kernel/mod.rs`, content unchanged) |
| S-PG | `rust/parser` | `parse/gates.rs`, `parse/gates/{word,body,argument}.rs`, `parse/gates/argument/pairs.rs` |
| S-PP | `rust/parser` | `parse/lexical.rs`, `parse/argument_values.rs`, `parse/identified_by.rs`, `parse/attribute.rs`, `parse/nested_body.rs`, `parse/not_implemented.rs` |
| S-LEX | `rust/parser` | `lex.rs` (thin) + `lex/{text,shape,do_block,receiver}.rs` + `lex/shape/opener.rs` |
| S-EMIT | `rust/parser` | `emit.rs` (thin) + `emit/{writer,ir_to_json}.rs` |
| S-RV | `rust/parser` | `ruby_value.rs` (thin) + `ruby_value/{to_source,from_source}.rs` |
| S-AUTH | `rust/host` | `auth.rs` (thin) + `auth/{token,oauth,session,member}.rs` |
| S-WEB | `rust/host` | `web.rs` (thin) + `web/{login_routes,ir_lookup,field_shape,params,crud_routes,form_render,encoding,response}.rs` |
| S-JOURNAL | `rust/host` | `journal.rs` (thin) + `journal/{replay,naming,lineage}.rs` |

S-K needs no integration slice — it's a pure rename, `crate::kernel::X` paths never change.

### Wave 1 — sequential per crate, parallel across crates

| Slice | Crate | Does |
|---|---|---|
| I-PARSER | `rust/parser` | Shrink `parse/mod.rs` → delete, replace with the new `parse.rs`; delete `walk_body`/`handle_call`; wire `pub mod gates;` etc. Update every call site in `parse/{file,hecksagon,process_manager,read_model,query,domain_port,policy,command,aggregate,chapter,value_object,lifecycle,entity}.rs` and `build/{query_options,query_derive,closed_sets}.rs` to the new qualified paths. Update `main.rs`'s module doc (`parse::word_gate` → `parse::gates::word::gate`, etc.; "see parse/mod.rs" → "see parse/gates.rs"/"lex.rs"). Update `tests/gates.rs` header prose if it names moved functions. `cargo build`, then `cargo test`. |
| I-HOST | `rust/host` | Shrink `auth.rs`/`web.rs`/`journal.rs` to their thin spines. Update the ~35 call sites across `web.rs`↔`auth.rs`↔`journal.rs`↔`dispatch.rs`↔`main.rs`. Do a pass over the stray file-path mentions in `bin/project_deploy`, `bin/project_field_hints`, `bin/rust_coverage`, `deploy/*/template.yaml` doc comments (cosmetic, non-blocking). `cargo build`, then `cargo test`. |
| I-CODEGEN | `rust/codegen` | Shrink `json.rs` to its thin spine + `json/parser.rs`. Zero external call-site churn (`Json`'s public API is unchanged; `Parser` was already fully private). Delete confirmed-dead `as_f64`/`as_i64`. Run `cargo build -W dead_code` and act on the `Display` impl per the flag above. `cargo test`. |
| I-BUILD | `rust/build` | Shrink `json.rs` to its thin spine + `json/{parser,writer}.rs`. Update the 2 `write` call sites in `pipeline.rs`. Run `cargo build -W dead_code` and act on `as_array` per the flag above. `cargo test`. |

### Verification

Pure internal reorganization, no intended behavior change — `cargo build` + `cargo test` per
crate is the bar, not a Ruby-side re-run (no IR/wire-format changes anywhere in this plan).
`rust/parser/tests/gates.rs` and its fixtures are the parser crate's own regression net;
`dispatch.rs`'s existing integration suite (real Postgres + compiled `.wasm`) is the host crate's.
