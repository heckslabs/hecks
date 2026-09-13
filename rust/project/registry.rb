module RustProjection
  module Projector
    module_function

    # ── THE JSON COMMAND ROUTER — `dispatch_by_name`'s own per-domain
    # table, generated once (domain_generator.rb calls this last, after
    # every aggregate's own file is written). One `Store` field per
    # generated aggregate — an `InMemoryRepository<T>`, the only
    # `Repository` impl this kernel ships (kernel/repository.rs) — and one
    # match arm per generated command (`command_skip_reason`'s survivors
    # only; a skipped command was never given a `dispatch_*` function to
    # route to either). `kernel/cli.rs` is the one caller: it knows verbs
    # and JSON, nothing domain-specific: this table is the whole bridge.
    #
    # `aggregates` is `[{name:, mod:, record:, commands: [{verb:, fn:,
    # args_struct:, creates:, reference_checks:, role:}], entity_commands:
    # [{verb:, entity_record:, fn:, args_struct:, reference_checks:,
    # role:}]}]` — accumulated by domain_generator.rb while it walks the
    # real IR, not re-derived here. `reference_checks` is `[{field:,
    # optional:, target_mod:, target_name:, heads:}]` (`domain_generator.
    # rb`'s own `reference_checks` helper) — `CommandRules::References
    # #resolve_references`'s per-attribute walk, done at codegen time
    # instead of dispatch time. `role:` is the command's own declared
    # role string, or `nil` (most commands declare none) — `Command
    # #role`, exported verbatim.
    #
    # Both emitted HERE, in the router, rather than inside each command's
    # own `dispatch_*` function (commands.rb):
    #   - `resolve_references` needs `store` — every OTHER aggregate's
    #     repo, not just this command's own — which only exists at this
    #     level, the same way Ruby's own version reaches through
    #     `@registry.repository(domain, target)` rather than anything
    #     local to one command.
    #   - `refuse_role_mismatch` needs the CALLER's role, which arrives
    #     as this router's own `caller_role` parameter (`cli.rs`'s own
    #     per-step `role:` key) — commands.rb's generated functions have
    #     no equivalent parameter and shouldn't grow one just for this.
    # Emitted right after `from_json` succeeds and before the real
    # dispatch call, matching Ruby's own `DISPATCH_ORDER`: `refuse_role_
    # mismatch` then `resolve_references` run in that order, both after
    # argument normalization/coercion and strictly before `hydrate`/
    # `enforce_givens` — verified live: a dangling reference (0016's own
    # investigation) or a role mismatch is refused before the command's
    # OWN `given`s are even consulted.
    # `command_name` is the SHORT name (`command.hecks_name` — "Open",
    # not the qualified verb "Banking::Account.Open") — confirmed against
    # Ruby's own live wording: `"Open refused — role: Branch clerk, and
    # the caller stated Wrong Role"`.
    def emit_role_check(role, command_name)
      return nil unless role

      Exemplar.render("role_check", '"TmplRole"' => role.inspect, '"TmplCommandName"' => command_name.to_s.inspect)
    end

    def emit_reference_check(check)
      ident = rust_ident_field(check[:field])
      target_subs = { '"TmplTarget"' => check[:target_name].inspect, '"tmpl_heads"' => check[:heads].inspect }

      if check[:optional]
        Exemplar.render("reference_check_optional", target_subs.merge("tmpl_target_mod" => check[:target_mod], "tmpl_optional_field" => ident))
      else
        Exemplar.render("reference_check_required", target_subs.merge("tmpl_target_mod" => check[:target_mod], "tmpl_field" => ident))
      end
    end

    # `a[:chapter_mod]` — which top-level generated module (`meta`,
    # `embryonaut`, `governance`, ...) this aggregate's own .rs file
    # lives under (`domain_generator.rb`'s own header on why: `super::`
    # only resolves within the SAME directory, which stops being true
    # the moment aggregates from more than one chapter feed one merged
    # registry). `crate::generated::#{chapter_mod}::` is valid from
    # every caller of `emit_registry` — a single-chapter call (today's
    # per-domain `registry.rs`) and the merged multi-chapter one
    # (bin/project_rust's own new step) both resolve identically,
    # because a module can always name itself by its own absolute path.
    # `domain_name` is no longer a single shared param — `dump_arms`
    # reads `a[:domain_name]` PER aggregate instead (`domain_generator.
    # rb`'s own header on why: a merged multi-chapter registry would
    # otherwise mislabel every aggregate's own instance dump with
    # whichever ONE chapter name got passed in, e.g. every Governance/
    # Identity record showing up as "Embryonaut::whatever#id").
    def emit_registry(aggregates)
      chapter_path = ->(a) { "crate::generated::#{a[:chapter_mod]}::#{a[:mod]}" }
      store_fields = aggregates.map { |a| "    pub #{a[:mod]}: crate::kernel::InMemoryRepository<#{chapter_path.call(a)}::#{a[:record]}>," }
      store_inits  = aggregates.map { |a| "            #{a[:mod]}: crate::kernel::InMemoryRepository::new()," }

      dump_arms = aggregates.map do |a|
        prefix = "#{a[:domain_name]}::#{a[:name]}#"
        <<~RUST.rstrip
                  for (id, record) in self.#{a[:mod]}.entries() {
                      instances.push((format!("{}{}", #{prefix.inspect}, id), record.to_json()));
                  }
        RUST
      end

      # The mechanical inverse of `instances()` above, one `if let` per
      # aggregate trying its own "Domain::Aggregate#" prefix against
      # each seed key in turn — a key nothing here recognizes is
      # skipped, not refused (a seed built for a merged multi-chapter
      # Store, or reused loosely across a boundary this generator
      # doesn't fully control, shouldn't have to be exact). Exists for
      # `cli.rs`'s own new `"seed"` input field — a HOST (rust/host,
      # docs/decisions/0012) seeding prior state back in instead of
      # replaying full command history from scratch every invocation.
      seed_arms = aggregates.map do |a|
        mod_path = chapter_path.call(a)
        prefix = "#{a[:domain_name]}::#{a[:name]}#"
        <<~RUST.rstrip
                  if let Some(id) = key.strip_prefix(#{prefix.inspect}) {
                      store.#{a[:mod]}.save(id, #{mod_path}::#{a[:record]}::from_json(value)?);
                      continue;
                  }
        RUST
      end

      # THE MINIMAL QUERY ENGINE'S OWN AGGREGATE LOOKUP — one `if` per
      # aggregate, tried against a bare "Domain::Aggregate" prefix (no
      # trailing "#", unlike `dump_arms`/`seed_arms` above: there is no
      # id to strip here, the WHOLE string names one aggregate, not one
      # record). kernel/cli.rs's ad hoc "query" step (the object form)
      # is the one caller — see repository.rs's own `filter_entries` and
      # query_comparators.rs's own header for what happens to the
      # listing this hands back.
      query_arms = aggregates.map do |a|
        prefix = "#{a[:domain_name]}::#{a[:name]}"
        <<~RUST.rstrip
                  if aggregate == #{prefix.inspect} {
                      return Some(self.#{a[:mod]}.entries().map(|(id, record)| (id.clone(), record.to_json())).collect());
                  }
        RUST
      end

      aggregate_arms = aggregates.flat_map do |a|
        mod_path = chapter_path.call(a)
        a[:commands].map do |c|
          # A CREATING command's own IDENTITY-EXTRA parameters — the bare,
          # not-a-declared-attribute `identified_by` heads
          # (`identity_components`'s third shape, mutations.rb —
          # `owner_id`, the corpus's one real example) that never made it
          # into `c[:args_struct]`. Read straight off `args_json` the same
          # way `id_line` below already reads an ACTING command's own `id`
          # — a bare top-level JSON field, not something `from_json`'s
          # typed struct carries — then passed positionally into
          # `dispatch_call`, in the exact order `commands.rb`'s own
          # `fn_signature` declared them (`identity_extra_params +
          # ["args: ...", ...]`, emit_command, read directly).
          # `Refusal::NotFound`, not `TypeMismatch` — a wholly absent
          # `owner_id` is exactly `CommandInterpreter#hydrate`'s own
          # "creating_no_identity" case (`Identity.of` reads `nil` for a
          # part `args.key?` doesn't have, which poisons the whole
          # identity), never a value that arrived and merely didn't
          # parse.
          extra_names  = Array(c[:identity_extra_params])
          extra_idents = extra_names.map { |name| rust_ident_field(name) }
          extra_lines  = extra_names.zip(extra_idents).map do |name, ident|
            "let #{ident} = facts_json.dig(#{name.to_s.inspect}).ok_or_else(|| crate::kernel::Refusal::NotFound(#{"#{c[:verb]} creates a #{a[:record]} — pass #{name}".inspect}.to_string()))?.to_id_component()?;"
          end
          extra_pass = extra_idents.map { |ident| "&#{ident}, " }.join

          # BUG#22 (QualityControl ledger) — a CREATING command's own
          # generated `dispatch_*` fn now takes `route` too (right after
          # `repo`, mirroring where an ACTING command's own `&id` already
          # sits): `route` is ALREADY bound above, for every arm, whether
          # or not a creating command used to read it — see this file's
          # own header on `id_line`/`route` for why. `commands.rb`'s own
          # header on this exact change has the full story on what the
          # generated function does with it now.
          dispatch_call = "#{mod_path}::dispatch_#{c[:fn]}(&mut store.#{a[:mod]}, #{c[:creates] ? "route, #{extra_pass}" : '&id, '}args, mutations, owner_deref, command_deref)"
          # ROUTING SEPARATION (`to:`/`with:`) — `CommandInvocation` reads
          # either the explicit routed/facts shape or the legacy mixed-
          # args object (rust/src/kernel/routing.rs, this file's own
          # target). An ACTING command's own `id` comes from the route
          # when one was given (`route.require_depth(0)?` — an aggregate-
          # level command addresses no entity), falling back to `extract_
          # id` against `facts_json` for the legacy shape, matching
          # `CommandInterpreter#hydrate_existing`'s own `route ||
          # identity_of(...)` order exactly.
          # BUG#20 (qa/bluebook/quality_control.bluebook) — `extract_id`'s
          # own `no identity found at all` case (every one of its tried
          # sources — the composite identity, `id`, and the command's own
          # reference key — came back empty, including a caller-supplied
          # `id: null`, which `to_id_component` refuses and this call
          # site used to let propagate raw) always raised `TypeMismatch`.
          # `CommandInterpreter#hydrate_existing`'s own identical fallback
          # chain (`identity_of || identity_from(:id) ||
          # identity_from(reference_key) || raise(...)`,
          # command_interpreter.rb, read directly) raises
          # `NotFound`/`acting_no_identity` instead — this IS `dispatch`
          # (kernel/dispatch.rs)'s own `Hydrate::Act` NOT-FOUND site's
          # upstream twin: an ACTING command's id is resolved HERE, at the
          # router, before `dispatch` (and its already-correct
          # `Hydrate::Act` repo.find-miss `NotFoundRecordMissing` check)
          # is ever called at all, so `dispatch` itself never saw this
          # case to refuse correctly. `extract_id` has no per-command
          # context (command name, declared identity reading) of its own
          # to render `RefusalSite::NotFoundActingNoIdentity` — its ONE
          # possible `Err` is wrapped here, where both are already in
          # scope, into the exact same wording
          # `RefusalWording.render("NotFound", "acting_no_identity", ...)`
          # produces on the Ruby side.
          acting_no_identity_message = "#{c[:name]} acts on an existing #{a[:record]} — pass #{Array(a[:identified_by]).join(', ')}:"
          # BUG#56 (qa/bluebook/quality_control.bluebook) — an ACTING
          # command's own `id_line`, below, already validates an explicit
          # `to:`'s route depth EAGERLY, ahead of `role_line` — matching
          # Ruby's own `Dispatcher#dispatch`, which resolves `Routing.
          # envelope(to)` unconditionally, for EVERY aggregate command,
          # creating or acting alike, strictly before `@commands.call`
          # (the door to `CommandInterpreter`'s own `DISPATCH_ORDER`,
          # `refuse_role_mismatch` included) ever runs. A CREATING
          # command's own generated `dispatch_*` function (`commands.rb`)
          # already runs the SAME `route.require_depth(0)?` check — but
          # only INTERNALLY, deep inside its own `Hydrate::Create`/
          # `Hydrate::Act` decision, built as an ARGUMENT to `crate::
          # kernel::dispatch(...)` — and this router only ever calls that
          # generated function (`dispatch_call`, below) AFTER `check_role`
          # has already run, above. A caller offering an explicit,
          # wrong-depth `to:` (an entity route on an aggregate-level
          # creating command, say — undeclared, route-shaped, the exact
          # `routing_key` adversarial mutation `Adversary::ROUTING_SHAPES`
          # produces) alongside an unauthorized actor used to refuse
          # `Unauthorized` here, where Ruby had already refused
          # `TypeMismatch` on the route itself before ever reaching a role
          # check at all — confirmed live, `Governance::RoleTransition.
          # Grant`, `bin/qa_sweep banking --seeds 40 --adversarial 0.3
          # --role-draw 0.25`. This line closes that gap the same way
          # `id_line` already does for an acting command: eagerly, ahead
          # of everything else in this arm — a plain validation, not an
          # identity computation (a creating command's own identity comes
          # from its declared attributes, never from `route`), so nothing
          # is bound from it.
          creating_route_precheck_line = "if let Some(route) = route { route.require_depth(0)?; }"
          # `collision_key` — BUG#54 (qa/bluebook/quality_control.bluebook)
          # — a WIRE-KEY COLLISION `structural_precheck_line` (BUG#23)
          # can't reach: `LedgerOrdering::Folder.AddSlip`'s bare
          # `reference_to Folder` addresses the aggregate through this
          # `id_line` using `a[:identified_by]`'s own head name
          # (`reference` — no `as:` mints a separate wire key) — the SAME
          # wire key `AddSlip` also separately declares as its own typed
          # argument (`attribute :reference, SlipReference`, a DIFFERENT
          # value-object type than the aggregate's own identity type). A
          # malformed `reference` (`null`, `{}`, or `{value: ""}` — every
          # shape `extract_id` itself refuses, directly or through
          # `to_id_component`'s own empty-string guard, R4) makes
          # `extract_id` fail to resolve ANY identity (BUG#20's own case)
          # and `id_line` below wraps that into `NotFound` before `#{c[:
          # args_struct]}::from_json` — the one place `SlipReference`'s
          # own `required`/pattern check on this SAME key would raise
          # `TypeMismatch` — ever runs. Ruby's `normalize_args` types
          # EVERY declared attribute (`reference` included, regardless of
          # it ALSO being this command's addressing key) unconditionally
          # before `hydrate`, so it always reaches `TypeMismatch` first;
          # `id_line`'s ordering can't, structurally, for this collision.
          #
          # `collision_key` finds this predicate's ONE colliding attribute
          # (`a[:identified_by]` is exactly one head AND that head's
          # plain name is among `c[:attributes]`) — `nil` for every
          # command in the real corpus and every OTHER command in this
          # stress domain today (confirmed: no aggregate-level acting
          # command anywhere else bare-references its owner AND
          # redeclares that SAME name as its own attribute; verified by
          # grepping every `identified_by`/`reference_to`/`attribute`
          # triple in `examples/` and `qa/stress_domains/`) — so `id_line`
          # below takes its ORIGINAL, UNCHANGED shape, and generated
          # output is BYTE-IDENTICAL, for every command but this one.
          #
          # When the predicate DOES hold, `id_line` no longer wraps
          # `extract_id`'s failure straight into `NotFound` — it tries
          # this command's OWN, already-generated argument pipeline
          # FIRST, inside `extract_id`'s own `Err` arm: the identical
          # `#{c[:args_struct]}::from_json(facts_json)` call `*extra_
          # lines, "let args = ..."` already makes two lines down, PLUS
          # this command's own `invariant_check_lines` (the identical
          # `args.<field>.check_invariants()?` calls this match arm's
          # body already runs after `args::from_json` succeeds) — spliced
          # in VERBATIM, not re-derived, so there is zero risk of drift
          # between this early copy and the real one. Only if THAT
          # produces no refusal at all does the code fall through to the
          # ORIGINAL `NotFound`/`acting_no_identity` wording. This closes
          # every malformed shape `extract_id` itself can ever refuse on
          # (not just `null`/`{}}`, a narrower version of this fix tried
          # first and found insufficient — BUG#54's own adversarial
          # mutation family also produces a THIRD shape, a syntactically
          # well-formed `{value: ""}` that `to_id_component`'s own R4
          # empty-string guard refuses at `extract_id` while `Slip
          # Reference`'s own pattern still fails it identically) WITHOUT
          # having to enumerate them: `extract_id` failing at all is
          # exactly the one condition needed, since `extract_id`'s own
          # composite-identity path and this command's own value-object
          # field read the EXACT SAME underlying JSON — whenever one
          # cannot find a usable value neither can the other, so this can
          # never turn a case where Ruby's `normalize_args` silently
          # succeeds (deferring to a real `hydrate` `NotFound`, matching
          # what `id_line` already answered before this fix) into a
          # wrongly-surfaced argument refusal instead.
          #
          # That "only inside `extract_id`'s OWN failure arm" gate is
          # deliberate, not incidental: it is what keeps this from being
          # either of the two shapes already tried here and reverted —
          #   1. NOT BUG#4's own first attempt (PR #529's commit message)
          #      — deferring EXISTENCE-CHECKING broadly past argument
          #      parsing for every command; the happy path (`extract_id`
          #      resolving an identity, the overwhelming majority of
          #      calls) is entirely untouched — this only ever runs
          #      inside the ALREADY-failing arm, and only ever for the
          #      one command matching the collision predicate above.
          #   2. NOT BUG#38's own first attempt (this file's `entity_
          #      commands` header, domain_generator.rb) — running a
          #      declared argument's OWN value-object coercion UNGATED,
          #      on the happy path, before `extract_id` runs at all,
          #      which surfaced a separate, still-open bug (BUG#41: a
          #      single-attribute value object's own `from_json` refuses
          #      `UnknownArgument` on an object with an extra key BEFORE
          #      its own missing-field check). This fix's own early
          #      argument pipeline runs STRICTLY AFTER `extract_id` has
          #      ALREADY failed — an input shaped so BUG#41's own gap
          #      could fire here (an extra key on an object that is ALSO
          #      missing the field `extract_id` itself needs) was ALREADY
          #      going to diverge from Ruby before this fix (as `NotFound`
          #      instead of whatever Ruby's `normalize_args` truly raises,
          #      the exact BUG#54 shape) — this fix can only ever trade
          #      one already-wrong answer for BUG#41's own, separately-
          #      catalogued one on that narrow slice, never break a case
          #      that agreed before it.
          identity_heads = Array(a[:identified_by]).map { |path| path.split(".").first }
          collision_key = (!c[:creates] && identity_heads.length == 1 && c[:attributes].include?(identity_heads.first)) ? identity_heads.first : nil
          not_found_expr = "crate::kernel::Refusal::NotFound(#{acting_no_identity_message.inspect}.to_string())"
          id_line =
            if c[:creates]
              creating_route_precheck_line
            elsif collision_key
              collision_fallback = ["let args = #{mod_path}::#{c[:args_struct]}::from_json(facts_json)?;", *c[:invariant_check_lines], "return Err(#{not_found_expr});"].join(" ")
              "let id = match route { Some(route) => { route.require_depth(0)?; route.aggregate().to_string() }, None => match #{mod_path}::#{a[:record]}::extract_id(facts_json) { Ok(resolved) => resolved, Err(_) => { #{collision_fallback} } }, };"
            else
              "let id = match route { Some(route) => { route.require_depth(0)?; route.aggregate().to_string() }, None => #{mod_path}::#{a[:record]}::extract_id(facts_json).map_err(|_| #{not_found_expr})?, };"
            end
          # BUG#23 (qa/bluebook/quality_control.bluebook) — Ruby's own
          # `DISPATCH_ORDER` runs `refuse_unknown_arguments`/`refuse_
          # absent_arguments` structurally BEFORE `hydrate`, but `id_line`
          # just above (an ACTING command's own identity resolution) used
          # to run BEFORE `#{c[:args_struct]}::from_json` — the ONE place
          # those structural checks lived — every single time, so a
          # malformed `id`/`to:` (a route-shaped `{aggregate:, entities:}`
          # value offered where the command declares a plain scalar
          # identity, say) short-circuited the whole dispatch via `extract_
          # id`'s own `?`/`NotFound`-wrap before a missing OTHER argument
          # was ever checked — Ruby and Rust then refused DIFFERENT KINDS
          # for the identical malformed command. `Projector.structural_
          # precheck` (json_codec.rb) builds the IDENTICAL unknown/absent-
          # argument check text `#{c[:args_struct]}::from_json` already
          # runs internally — run a SECOND time, standalone, here, against
          # the raw `facts_json` `v` is bound to, BEFORE `id_line`. Nil for
          # a CREATING command (`domain_generator.rb`'s own gate on this
          # field: `id_line` above is never emitted for one either, so
          # there is no race for this to close there). Deliberately
          # redundant with the copy still inside `#{c[:args_struct]}::
          # from_json` itself (unchanged) rather than replacing it — the
          # same "can only ever refuse SOONER with the exact kind `from_
          # json` would have produced anyway, never diverge from it" shape
          # `invariant_check_lines` below already established for R3 (see
          # that field's own comment) — NOT the reordering BUG#4 (PR #529)
          # already tried and reverted: `id_line` itself still runs in
          # exactly the same place, unchanged; this only adds an EARLIER,
          # narrower gate ahead of it, scoped to a command's own declared
          # argument shape, never to record existence.
          structural_precheck_line = c[:structural_precheck] ? "{ let v = facts_json; #{c[:structural_precheck]} }" : ""
          role_line = emit_role_check(c[:role], c[:name])
          reference_lines = c[:reference_checks].map { |check| emit_reference_check(check) }

          # `owner_deref`/`command_deref` — `given`/`ensures` cross-
          # aggregate dereference (`customer.status`, `account.customer.
          # status`), resolved HERE rather than inside the generated
          # `dispatch_*` function itself: it needs `store` (every OTHER
          # aggregate's own repo), which only exists at this router level
          # (`reference_lookup.rs`'s own header on why), and it must
          # finish — end its own borrow of `store` — BEFORE the `&mut
          # store.#{a[:mod]}` the dispatch call below takes; computing it
          # first, into plain owned data, is what keeps those two borrows
          # from ever overlapping. A CREATING command has no `id` yet (no
          # record exists to fetch), so `owner_deref` is trivially empty
          # — its OWN reference-typed attributes are already covered by
          # `command_deref` below (`reference_specs.rb`'s own header: a
          # creating command's attributes and its aggregate's are the
          # same attributes).
          owner_deref_expr = c[:creates] ? "Vec::new()" : "crate::kernel::owner_deref(&*store, REFERENCE_TABLE, #{"#{a[:domain_name]}::#{a[:name]}".inspect}, &id)"
          deref_lines = [
            "let owner_deref = #{owner_deref_expr};",
            "let command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, #{emit_reference_specs_literal(c[:reference_specs])}, &args);",
          ]

          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let route = invocation.route();",
                  "let facts_json = invocation.facts();",
                  structural_precheck_line,
                  id_line, *extra_lines, "let args = #{mod_path}::#{c[:args_struct]}::from_json(facts_json)?;",
                  # R3 FIX (docs/audits/2026-08-11-bug-triage.md) — VO
                  # invariant/admits/pattern BEFORE role_line/reference_lines,
                  # matching Ruby's own DISPATCH_ORDER (this file's own
                  # header, above, on why role/references are emitted here
                  # rather than inside the generated dispatch fn itself;
                  # `domain_generator.rb`'s own comment on `invariant_check_
                  # lines` has the full argument for why this is safe to run
                  # a second time, redundantly, inside that fn too).
                  *c[:invariant_check_lines], role_line, *reference_lines,
                  *deref_lines,
                  "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());",
                  "#{dispatch_call}.map(|(_, events)| stamp_payload(events, &payload))"].compact.reject(&:empty?)

          "          #{c[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      # Entity commands never create — both the parent's identity and the
      # addressed element's own are always read off the raw JSON
      # (`extract_id` reused for both: an entity's own IR shape carries
      # `identified_by` the same way an aggregate's does — json_codec.rb's
      # `emit_extract_id` header). `commands.rb`'s `emit_entity_command`
      # names the generated function `dispatch_entity_<fn>` — the
      # `"entity_" + fn` this file's own `fn:` entries already carry.
      entity_arms = aggregates.flat_map do |a|
        mod_path = chapter_path.call(a)
        a[:entity_commands].map do |c|
          role_line = emit_role_check(c[:role], c[:name])
          reference_lines = c[:reference_checks].map { |check| emit_reference_check(check) }
          dispatch_call = "#{mod_path}::dispatch_entity_#{c[:fn]}(&mut store.#{a[:mod]}, &parent_id, &element_id, &element_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))"

          # `element_wants` — `entity_element_missing`'s one genuinely
          # RUNTIME piece (`kernel::dispatch_entity`'s own header): the
          # caller-OFFERED scalar identity VALUES, read straight off the
          # same raw JSON `element_id` already digs, just joined with ", "
          # instead of ":" (`emit_extract_wants`, json_codec.rb). Computed
          # unconditionally, alongside `element_id`, never only on the
          # refusal path — it's a plain infallible dig, not worth gating
          # behind whether the dispatch actually fails.
          #
          # `owner_deref` — BUG#40 fix: carries the PARENT aggregate's own
          # `reference_to`/`belongs_to` fields, dereferenced off the
          # already-known `parent_id`, EXACTLY the same call an
          # aggregate-level `Act` command already makes for its own `id`
          # (this file's own `owner_deref_expr`, above). This is what
          # `seeded_projections` (reference_lookup.rs) needs to re-seed the
          # PARENT's own `projects` fields (`ACCOUNT_PROJECTED_FIELDS`'s
          # `reference: "customer"`) on every entity-command save —
          # `dispatch_entity` (dispatch.rs) unconditionally re-applies every
          # `seed_projections` entry, aggregate-level `Act` or entity-level
          # alike, so an entity command needs the SAME reference-keyed
          # derefs (`"customer"`) an aggregate command's own `owner_deref`
          # already supplies, not only `command_deref`'s `"parent"` entry
          # (used for `parent.X`-style given/ensures lookups — a different
          # name, a different shape: one un-spread node, not spread across
          # top-level reference names). Before this fix this was
          # unconditionally `Vec::new()`, so `seeded_projections` could
          # never resolve `"customer"` here and every entity command wiped
          # the field to `null` — see BUG#40.
          #
          # An entity's OWN `reference_to` attributes (dereferenced off the
          # addressed ELEMENT itself, a different thing again — REAL,
          # still-open gap, unaffected by this fix) would need this router
          # to find the parent AND match the one addressed element BEFORE
          # `dispatch_entity` itself does. No entity in this corpus declares
          # a reference-typed attribute of its own (confirmed against the
          # real IR, not assumed), so nothing here is silently wrong today.
          #
          # `command_deref` covers the entity command's OWN reference-typed
          # arguments (`reference_specs.rb`) PLUS — merged in, matching
          # `CommandRules::Admissibility#enforce_givens`'s own `parent:`
          # tier exactly — the PARENT aggregate's own dereferenced state
          # under the ONE name `parent.account.customer.status` reads:
          # `crate::kernel::parent_deref` fetches the parent record this
          # router already addresses by `parent_id` and recursively
          # resolves ITS OWN `reference_to` attributes off it.
          # AN ENTITY COMMAND'S OWN ROUTE, when one was given, addresses
          # exactly one entity beneath the parent aggregate
          # (`route.require_depth(1)?`) — the SAME `to: { aggregate:,
          # entity: }` shape a mutating meta-domain command already
          # dispatches through (`SyntaxBoot#admit_keywords`, this file's
          # own header on that convention). Falls back to the legacy
          # `extract_id`/`extract_wants` pair against `facts_json` when
          # unrouted, matching the aggregate arm's own `id_line` fallback.
          #
          # BUG#38 FIX — `structural_precheck_line`, the SAME BUG#23
          # standalone gate the aggregate arm's own `structural_precheck_
          # line` already runs (this file's header on that fix, above),
          # spliced INSIDE this `match route`'s route-less `None` arm
          # specifically, BEFORE its own `extract_id` calls. Without it, a
          # malformed `id` (a route-shaped `{aggregate:, entities:}` value
          # where the entity declares a plain scalar identity) always
          # short-circuited via `extract_id`'s own `?` before an unrelated
          # undeclared argument on the SAME call was ever checked,
          # refusing `TypeMismatch` where Ruby's `ArgumentGate` (which
          # always runs BEFORE `locate_element`) refuses `UnknownArgument`
          # first.
          #
          # SCOPED TO THE `None` ARM ONLY — NOT, like the aggregate arm's
          # own `id_line`, spliced before the WHOLE `match route` — this
          # is the one place entity dispatch genuinely differs from it.
          # `id_line`'s own `Some(route) => route.require_depth(0)?` can
          # NEVER itself refuse: an aggregate command's routed depth is
          # always 0, and the ONE shape that ever reaches this router with
          # an explicit but WRONG-shaped `to:` (the `routing_key` fuzz
          # mutation's `scalar` case) parses into a route with ZERO
          # entities either way, satisfying depth 0 trivially — so
          # `structural_precheck_line`'s placement relative to `id_line`
          # was never actually observable there. An entity command's own
          # `Some(route) => route.require_depth(1)?` (or `require_depth(2)`
          # one hop deeper) is NOT trivially satisfied by that same zero-
          # entity route — confirmed live (`qa/stress_domains/nested_
          # pieces`, `Workspace.Board.AddCard` with a scalar `to:`
          # mutation): Ruby resolves an EXPLICITLY given `to:` entirely
          # independently of `facts`/`ArgumentGate` (`Routing.envelope`
          # runs off `to:` alone, never touching the command's own
          # declared-argument shape), so a wrong-depth explicit route
          # refuses on ITS OWN terms, `TypeMismatch`, before Ruby's
          # absent-argument check on the UNRELATED `facts` payload is ever
          # reached — moving `structural_precheck_line` ahead of the
          # WHOLE match (a first attempt at this exact fix) refused
          # `AbsentArgument` instead, a genuine new divergence this
          # narrower placement avoids. Ruby's `ArgumentGate` and
          # `locate_element` only ever share the SAME data (`facts`) in
          # the route-LESS case, which is the only case this fix needs to
          # reorder at all.
          structural_precheck_line = c[:structural_precheck] ? "{ let v = facts_json; #{c[:structural_precheck]} }" : ""
          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let route = invocation.route();",
                  "let facts_json = invocation.facts();",
                  "let (parent_id, element_id, element_wants) = match route { Some(route) => { route.require_depth(1)?; let element_id = route.entities()[0].clone(); (route.aggregate().to_string(), element_id.clone(), element_id) }, None => { #{structural_precheck_line} let parent_id = #{mod_path}::#{a[:record]}::extract_id(facts_json)?; let element_id = #{mod_path}::#{c[:entity_record]}::extract_id(facts_json)?; let element_wants = #{mod_path}::#{c[:entity_record]}::extract_wants(facts_json); (parent_id, element_id, element_wants) }, };",
                  "let args = #{mod_path}::#{c[:args_struct]}::from_json(facts_json)?;",
                  # R3 FIX — see the aggregate arm's own identical comment,
                  # above.
                  *c[:invariant_check_lines], role_line, *reference_lines,
                  "let owner_deref = crate::kernel::owner_deref(&*store, REFERENCE_TABLE, #{"#{a[:domain_name]}::#{a[:name]}".inspect}, &parent_id);",
                  "let mut command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, #{emit_reference_specs_literal(c[:reference_specs])}, &args);",
                  "if let Some(parent_node) = crate::kernel::parent_deref(&*store, REFERENCE_TABLE, #{"#{a[:domain_name]}::#{a[:name]}".inspect}, &parent_id) { command_deref.push((\"parent\", parent_node)); }",
                  "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());",
                  dispatch_call].compact.reject(&:empty?)

          "          #{c[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      # BUG#11 (loop-parity) — A COMMAND OWNED BY AN ENTITY NESTED TWO
      # LEVELS DEEP. `commands.rb`'s own `dispatch_entity_<entity>_
      # <nested>_<fn>` names the generated function
      # (`domain_generator.rb`'s own `nested_entity_commands` accumulator,
      # `fn:` computed identically there).
      #
      # BUG#19 (loop-parity) — `c[:unrouted_supported]` (domain_
      # generator.rb's own header on when it's true) now picks between
      # the SAME `Some(route) => ... | None => ...` shape `entity_arms`
      # above already has (extended one hop deeper: `hop1_id`/`hop1_
      # wants` resolved off `entity`'s own `extract_id`/`extract_wants`,
      # `hop2_id`/`hop2_wants` off `nested`'s own — both newly emitted by
      # `domain_generator.rb` for this) and the ROUTED-only shape BUG#11
      # originally shipped (kept, unchanged, for a domain whose identity
      # shape at either hop isn't `extract_id`-supported yet —
      # `json_codec.rb#extract_id_supported?`). `route.require_depth(2)`
      # is the ordinary `RoutingEnvelope` check every OTHER depth already
      # uses (`require_depth(0)`/`require_depth(1)` above) — nothing
      # about the wire format itself changes with depth, in EITHER arm.
      nested_entity_arms = aggregates.flat_map do |a|
        mod_path = chapter_path.call(a)
        Array(a[:nested_entity_commands]).map do |c|
          role_line = emit_role_check(c[:role], c[:name])
          reference_lines = c[:reference_checks].map { |check| emit_reference_check(check) }
          dispatch_call = "#{mod_path}::dispatch_entity_#{c[:fn]}(&mut store.#{a[:mod]}, &parent_id, &hop1_id, &hop1_wants, &hop2_id, &hop2_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))"

          # BUG#38 FIX — see the one-level `entity_arms`' own identical
          # header, above, including WHY this is scoped to the route-less
          # `None` arm alone (spliced INSIDE it, before its own
          # `extract_id` calls) rather than before the whole `match route`
          # the way a first attempt at this fix (reverted) tried: an
          # explicit but wrong-depth `to:` refuses on its OWN terms in
          # `Some(route)`, independently of `facts`, before Ruby's
          # absent-argument check on that unrelated payload is ever
          # reached. `nil` (never spliced in) when `unrouted_supported` is
          # false: the `else` branch below always requires an explicit
          # route and never calls `extract_id` against raw `facts_json`
          # at all, so there is no route-less arm here for this to close.
          structural_precheck_line = c[:structural_precheck] ? "{ let v = facts_json; #{c[:structural_precheck]} }" : ""
          route_binding =
            if c[:unrouted_supported]
              "let (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) = match route { Some(route) => { route.require_depth(2)?; let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); (route.aggregate().to_string(), hop1_id.clone(), hop1_id, hop2_id.clone(), hop2_id) }, None => { #{structural_precheck_line} let parent_id = #{mod_path}::#{a[:record]}::extract_id(facts_json)?; let hop1_id = #{mod_path}::#{c[:entity_record]}::extract_id(facts_json)?; let hop1_wants = #{mod_path}::#{c[:entity_record]}::extract_wants(facts_json); let hop2_id = #{mod_path}::#{c[:nested_record]}::extract_id(facts_json)?; let hop2_wants = #{mod_path}::#{c[:nested_record]}::extract_wants(facts_json); (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) }, };"
            else
              "let route = route.ok_or_else(|| crate::kernel::Refusal::TypeMismatch(#{"#{c[:verb]} addresses an entity nested two levels deep — requires an explicit to: { aggregate:, entities: [...] } route".inspect}.to_string()))?; route.require_depth(2)?; let parent_id = route.aggregate().to_string(); let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); let hop1_wants = hop1_id.clone(); let hop2_wants = hop2_id.clone();"
            end

          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let route = invocation.route();",
                  "let facts_json = invocation.facts();",
                  route_binding,
                  "let args = #{mod_path}::#{c[:args_struct]}::from_json(facts_json)?;",
                  *c[:invariant_check_lines], role_line, *reference_lines,
                  # BUG#40 fix — see `entity_arms`'s own identical comment,
                  # above: the top-level PARENT aggregate's own
                  # `#{AGGREGATE}_PROJECTED_FIELDS` is what `seed_projections_
                  # binding` scopes a nested entity command's re-seeding to
                  # too (`commands.rb`'s `seed_projections_binding(aggregate)`
                  # takes the OUTER `aggregate`, never the nested entity), so
                  # `owner_deref` here needs that SAME top-level `a`'s own
                  # reference fields, dereferenced off `parent_id`.
                  "let owner_deref = crate::kernel::owner_deref(&*store, REFERENCE_TABLE, #{"#{a[:domain_name]}::#{a[:name]}".inspect}, &parent_id);",
                  "let command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, #{emit_reference_specs_literal(c[:reference_specs])}, &args);",
                  "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());",
                  dispatch_call].compact.reject(&:empty?)

          "          #{c[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      # PORT OPERATIONS — no `creates` line (a port neither hydrates nor
      # saves an aggregate instance, `ports.rb`'s own header), otherwise
      # the exact same shape a command's own arm has: `from_json`, THEN
      # every reference check (still emitted HERE, not in ports.rb, for
      # the identical reason a command's own are — `store`, every OTHER
      # aggregate's repo, only exists at this level), then the dispatch
      # call. No role check — `PortOperation` carries no `role:` at all (a
      # port has no caller to check a role against; the caller IS the
      # adapter). `stamp_payload` still runs, for the same reason a
      # command's own payload gets replaced with the router's raw facts
      # rather than the narrower typed struct's own re-derived one (this
      # file's own header).
      #
      # THE RECEIVER — `CommandInvocation#split_aggregate_receiver` reads
      # it from the route when one was given, or from `legacy_receiver_
      # field` (the operation's own migration-era self-reference
      # attribute, when it still declares one — `ports.rb`'s own header)
      # against the legacy mixed-facts shape otherwise; either way the
      # receiver is stripped OUT of the facts the generated `Args::
      # from_json` sees, matching `emit_port_operation`'s own exclusion of
      # that same field from the args struct entirely. Existence is
      # checked here, once, before the dispatch call runs — the port's own
      # generated function trusts the record it addresses is real, the
      # same trust `owner_deref`/`command_deref` already extend to an
      # acting command's own referenced records.
      port_arms = aggregates.flat_map do |a|
        mod_path = chapter_path.call(a)
        a[:ports].map do |p|
          reference_lines = p[:reference_checks].map { |check| emit_reference_check(check) }
          legacy_receiver = p[:legacy_receiver_field] ? "Some(#{p[:legacy_receiver_field].to_s.inspect})" : "None"
          to_receiver = p[:to_receiver_field] ? "Some(#{p[:to_receiver_field].to_s.inspect})" : "None"
          dispatch_call = "#{mod_path}::dispatch_operation_#{p[:fn]}(&id, args).map(|events| stamp_payload(events, &payload))"

          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let (id, port_facts) = invocation.split_aggregate_receiver(#{legacy_receiver}, #{to_receiver})?;",
                  "let facts_json = &port_facts;",
                  "let _instance = store.#{a[:mod]}.find(&id).ok_or_else(|| crate::kernel::Refusal::NotFound(format!(\"#{a[:name]} {:?} does not exist\", id)))?;",
                  "let args = #{mod_path}::#{p[:args_struct]}::from_json(facts_json)?;", *reference_lines,
                  "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());",
                  dispatch_call].compact

          "          #{p[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      dispatch_arms = aggregate_arms + entity_arms + nested_entity_arms + port_arms

      header = <<~RUST
        // GENERATED by bin/project_rust — the JSON command router
        // `kernel::cli` dispatches every step through. Do not hand-edit —
        // re-run bin/project_rust instead.
        #![allow(dead_code, unused_variables)]

        // `Repository::save` (from_seed, below) is a TRAIT method —
        // `InMemoryRepository`'s own inherent methods (entries(), used
        // by instances()) need no import, but save() does.
        use crate::kernel::Repository;

      RUST

      body = Exemplar.render(
        "registry_file",
        "TmplStore2" => "Store",
        "    pub tmpl_field: crate::kernel::InMemoryRepository<i64>," => store_fields.join("\n"),
        "            tmpl_field: tmpl_store_fields_placeholder()," => store_inits.join("\n"),
        "tmpl_dump_arm_placeholder();" => dump_arms.join("\n"),
        "tmpl_seed_arm_placeholder();" => seed_arms.join("\n"),
        "tmpl_query_arm_placeholder();" => query_arms.join("\n"),
        '"tmpl_verb" => { tmpl_dispatch_arm_placeholder() }' => dispatch_arms.join("\n")
      )

      "#{header}#{body}"
    end

    # ── THE DOMAIN-WIDE REFERENCE TABLE + LOOKUP — `Store`'s own
    # `crate::kernel::ReferenceLookup` impl (`reference_lookup.rs`'s own
    # header on why this has to live here, keyed through `store`, rather
    # than inside any one command's own generated function) plus the
    # static `REFERENCE_TABLE` every `owner_deref`/`parent_deref`/
    # `command_deref` call this same file's own `aggregate_arms`/
    # `entity_arms` emit needs to keep recursing one hop further once
    # it's fetched a target record (`reference_lookup.rs`'s own
    # `specs_for`). One row per aggregate `emit_registry` above already
    # generated a `Store` field for — `a[:reference_specs]`, computed once
    # by `domain_generator.rb` off the real IR `attributes` list
    # (`reference_specs.rb`), not re-derived here.
    def emit_reference_table(aggregates)
      rows = aggregates.map do |a|
        qualified = "#{a[:domain_name]}::#{a[:name]}"
        "    (#{qualified.inspect}, #{emit_reference_specs_literal(a[:reference_specs])}),"
      end

      <<~RUST
        pub static REFERENCE_TABLE: crate::kernel::ReferenceTable = &[
        #{rows.join("\n")}
        ];
      RUST
    end

    # `find_fielded` — one `if` per aggregate, the identical "Domain::
    # Aggregate" prefix match `emit_registry`'s own `query_arms` already
    # uses, each routing to that ONE aggregate's own repository and
    # boxing whatever it finds as a type-erased `Fielded` — the fetched
    # record's OWN generated impl (already type-correct: `Value::Int`/
    # `Float`/`Str` exactly as declared), never a JSON-roundtripped
    # guess. Falls through to `None` for any target this domain never
    # declares (a genuine cross-domain reference — `references.rb`'s own
    # `resolve_references` already tolerates this the identical way) or
    # never generated (`unsupported_names`) — never a panic.
    def emit_reference_lookup(aggregates)
      arms = aggregates.map do |a|
        prefix = "#{a[:domain_name]}::#{a[:name]}"
        <<~RUST.rstrip
                  if target == #{prefix.inspect} {
                      return self.#{a[:mod]}.find(id).map(|r| Box::new(r) as Box<dyn crate::kernel::Fielded>);
                  }
        RUST
      end

      <<~RUST
        #{emit_reference_table(aggregates)}
        impl crate::kernel::ReferenceLookup for Store {
            fn find_fielded(&self, target: &str, id: &str) -> Option<Box<dyn crate::kernel::Fielded>> {
        #{arms.join("\n")}
                None
            }
        }
      RUST
    end
  end
end
