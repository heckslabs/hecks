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

    # `kernel::ArgumentGates` FOR ONE COMMAND (roadmap D2) — the struct
    # literal `decode_aggregate_arguments`/`decode_entity_arguments`
    # (rust/src/kernel/dispatch.rs) call one field of per declared
    # argument-gate step, in `AggregateStep::ORDER`/`EntityStep::ORDER`.
    # NOTHING here names that order: the first three fields are the
    # command's own generated gate functions (`Projector.emit_argument_
    # gates`, json_codec.rb), `normalize_args` is its `from_json` plus the
    # VO invariant/admits/pattern checks that used to be spliced after it
    # (R3), and the last two are the role and reference checks that used
    # to be emitted as bare lines further down the arm.
    #
    # Closures, not plain function references, for the last two: both
    # need `store`, which only exists at this router level.
    def emit_argument_gates_literal(args_path, invariant_check_lines, role_line, reference_lines)
      normalize = ["let args = #{args_path}::from_json(v)?;", *Array(invariant_check_lines).map { |line| squeeze(line) }, "Ok(args)"].join(" ")
      role = role_line ? "&|| { #{squeeze(role_line)} Ok(()) }" : "&|| Ok(())"
      references =
        if reference_lines.empty?
          "&|_args: &#{args_path}| Ok(())"
        else
          "&|args: &#{args_path}| { #{reference_lines.map { |line| squeeze(line) }.join(' ')} Ok(()) }"
        end

      "crate::kernel::ArgumentGates { " \
        "decode_arguments: &#{args_path}::decode_arguments, " \
        "refuse_unknown_arguments: &#{args_path}::refuse_unknown_arguments, " \
        "refuse_absent_arguments: &#{args_path}::refuse_absent_arguments, " \
        "normalize_args: &|v: &crate::kernel::Json| { #{normalize} }, " \
        "refuse_role_mismatch: #{role}, " \
        "resolve_references: #{references} }"
    end

    # An emitted check is a whole statement, sometimes several lines and
    # indented for the line-per-statement body it used to sit in; inside a
    # closure it is one expression among others.
    def squeeze(text) = text.to_s.split("\n").map(&:strip).reject(&:empty?).join(" ")

    def emit_reference_check(check)
      ident = rust_ident_field(check[:field])
      target_subs = { '"TmplTarget"' => check[:target_name].inspect, '"tmpl_heads"' => check[:heads].inspect }

      if check[:list_item]
        list_subs = { "tmpl_target_mod" => check[:target_mod], "tmpl_list_field" => ident,
                      "&item.tmpl_element_field" => check[:list_item] }
        Exemplar.render("reference_check_list", target_subs.merge(list_subs))
      elsif check[:optional]
        Exemplar.render("reference_check_optional", target_subs.merge("tmpl_target_mod" => check[:target_mod], "tmpl_optional_field" => ident))
      else
        Exemplar.render("reference_check_required", target_subs.merge("tmpl_target_mod" => check[:target_mod], "tmpl_field" => ident))
      end
    end

    # `emit_tenant_boundary_check(check)` — `domain_generator.rb`'s own
    # `tenant_boundary_checks` builds the plain Hash this reads; see that
    # method's header for the full argument. Hand-built via `format`
    # rather than an `Exemplar` shape (unlike `emit_reference_check`,
    # above): the TARGET side's own accessor needs a genuinely different
    # expression shape depending on whether the tenant attribute is a
    # single-attribute value object (`record.region.as_ref().map(|v|
    # v.value.clone())`) or an already-bare scalar (`record.region.
    # clone()`), which the fixed two-shape (`required`/`optional`)
    # `reference_check_*` templates have no slot for — the same "hand-
    # build the varying structure, keep the fixed skeleton fenced" split
    # `mutations.rb#entity_list_replace_guard` already makes.
    #
    # `RefusalSite::UnauthorizedCrossTenantReference`'s own template
    # (`refusal_wording.rb`) is `"{aggregate} {field} is {tenant}, but
    # {attribute} names a {target} whose own {target_field} is {other} —
    # a cross-tenant reference"` — a plain key-based replace-fold
    # (`RefusalWording.render`/`kernel/refusal_wording.rs`'s own `render`),
    # so the `(key, value)` pairs below need no particular order.
    # `format!("{:?}", ...)` on the bare unwrapped scalar matches `Rendering.
    # describe`'s own single-field unwrap for a String/Integer exactly
    # (Rust's `Debug` for `String` quotes the same way Ruby's
    # `String#inspect` does; for `Integer`, `{:?}` and `#inspect` both
    # print the bare digits) — the SAME reasoning `mutations.rb#entity_
    # list_replace_guard`'s own `offered_expr` comment already gives for
    # the identical technique.
    def emit_tenant_boundary_check(check)
      ref_ident = rust_ident_field(check[:reference_field])
      own_expr = "args.#{rust_ident_field(check[:own_accessor])}.clone()"

      target_accessor = check[:target_accessor]
      target_expr =
        if target_accessor.include?(".")
          head, inner = target_accessor.split(".", 2)
          "record.#{rust_ident_field(head)}.as_ref().map(|v| v.#{rust_ident_field(inner)}.clone())"
        else
          "record.#{rust_ident_field(target_accessor)}.clone()"
        end

      "if let Some(record) = store.#{check[:target_mod]}.find(&args.#{ref_ident}) { " \
        "if let Some(target_tenant) = #{target_expr} { " \
        "let own_tenant = #{own_expr}; " \
        "if target_tenant != own_tenant { " \
        "return Err(crate::kernel::Refusal::Unauthorized(crate::kernel::refusal_wording::UnauthorizedCrossTenantReferenceArgs { " \
        "aggregate: #{check[:aggregate_name].inspect}, " \
        "field: #{check[:own_tenant_field].to_s.inspect}, " \
        "tenant: &format!(\"{:?}\", own_tenant), " \
        "attribute: #{check[:reference_field].to_s.inspect}, " \
        "target: #{check[:target_name].inspect}, " \
        "target_field: #{check[:target_tenant_field].to_s.inspect}, " \
        "other: &format!(\"{:?}\", target_tenant)" \
        " }.render_args())); " \
        "} } }"
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
          # BUG#139 — `tenant_boundary_check` (an already-computed
          # `Result<(), Refusal>`, see this file's own `tenant_boundary_
          # lines`/`tenant_boundary_check_line` below) trails `command_
          # deref` here — the same "computed eagerly at router level,
          # applied deferred inside `dispatch()`" split `owner_deref`/
          # `command_deref` themselves already use, one more argument
          # wide.
          dispatch_call = "#{mod_path}::dispatch_#{c[:fn]}(&mut store.#{a[:mod]}, #{c[:creates] ? "route, #{extra_pass}" : '&id, '}args, mutations, owner_deref, command_deref, tenant_boundary_check)"
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
          # `RefusalWording.render_site("NotFound", "acting_no_identity",
          # ...)` produces on the Ruby side — off the same declared
          # template and the same argument rows, never re-typed here.
          # V3 — no longer a hand-typed copy of the template's own text:
          # the three declared arguments go over to the site's typed
          # `render_args`, so the wording itself lives in one place
          # (Vocabulary::RefusalTemplate) and a missing argument does not
          # compile.
          acting_no_identity_args =
            "crate::kernel::refusal_wording::NotFoundActingNoIdentityArgs { " \
            "command: #{c[:name].to_s.inspect}, aggregate: #{a[:record].to_s.inspect}, " \
            "identity: #{Array(a[:identified_by]).join(', ').inspect} }.render_args()"
          # BUG#56 (qa/bluebook/quality_control.bluebook) — the gap the
          # line below first closed, for a CREATING command: an explicit,
          # wrong-depth `to:` alongside an unauthorized actor refused
          # `Unauthorized` here where Ruby had already refused
          # `TypeMismatch` on the route itself (confirmed live,
          # `Governance::RoleTransition.Grant`, `bin/qa_sweep banking
          # --seeds 40 --adversarial 0.3 --role-draw 0.25`). A creating
          # command's own generated `dispatch_*` runs the same
          # `require_depth(0)?` INTERNALLY, but only once this router has
          # already called it — far too late.
          # ROUTE DEPTH FOR EVERY AGGREGATE COMMAND, CONDITIONALLY EAGER
          # (BUG#141/BUG#123, qa/bluebook/quality_control.bluebook) —
          # Ruby's own `Invocation.route` (invocation.rb) validates `to:`
          # inside `Invocation.from_call`, strictly before `@commands.
          # call` opens `CommandInterpreter::DISPATCH_ORDER` at all, so an
          # explicit wrong-depth route refuses `TypeMismatch` on its OWN
          # terms ahead of every argument gate — but ONLY for the LEGACY/
          # flat-facts shape. `Invocation.facts_for`'s own `with:`-shaped
          # validation (`refuse_unknown_facts!`/`refuse_absent_facts!`)
          # runs BEFORE `route(to)` when `with:` was given (`from_call`'s
          # own docstring: "facts first (`with:` checks), then `to:`" for
          # an `:aggregate` receiver) — the legacy shape's own `facts_for`
          # is a silent no-op, which is the ONLY reason `route(to)` reads
          # as "eager" there at all.
          #
          # THIS IS THE EXACT GAP D2 (#751) LEFT OPEN AND DOCUMENTED (this
          # comment used to read "ONE SHAPE THIS STILL DOES NOT REPRODUCE
          # ... pre-existing ... every corpus and matrix step uses the
          # loose-keyword form, where Ruby validates to: first and the two
          # agree") — that fixture gap is exactly why D2's own broad "route
          # depth, eagerly, for every aggregate command" landed with a
          # real regression nothing caught: `with:`-shaped facts that are
          # ALSO wrong (an undeclared key, say) alongside a wrong-depth
          # `to:` now refuse `TypeMismatch` in Rust where Ruby refuses
          # `UnknownArgument`/`AbsentArgument` first. `CommandInvocation::
          # explicit_with()` (rust/src/kernel/routing.rs) is the one bit
          # of runtime information needed to replicate BOTH orders
          # correctly, per call, instead of picking one fixed order for
          # every call — `route_precheck_line` (this same text D2 already
          # had) now runs AFTER `gates_expr` for an explicit `with:` call,
          # BEFORE it otherwise, inside `args_line`'s own `if invocation.
          # explicit_with() { ... } else { ... }` (below, once `gates_
          # expr` is built). DELIBERATELY NOT a blanket reorder the other
          # way either — BUG#4 (PR #529) and BUG#38's own first attempt
          # (PR #610) each already tried a fixed reorder and were reverted
          # once widened fuzz found Ruby's real order is itself
          # conditional; this is a per-call runtime branch on the actual
          # call shape, same as those two corrections needed to become.
          route_precheck_line = "if let Some(route) = route { route.require_depth(0)?; }"
          not_found_expr = "crate::kernel::Refusal::NotFound(#{acting_no_identity_args})"
          # IDENTITY RESOLUTION IS PART OF HYDRATE, AND NOW RUNS AFTER
          # EVERY ARGUMENT GATE (roadmap D2) — Ruby resolves an acting
          # command's record inside `step_hydrate` (`hydrate_existing`,
          # command_interpreter.rb), which `AggregateDispatchOrder` places
          # after `normalize_args`/`refuse_role_mismatch`/`resolve_
          # references`; this `extract_id` is that same resolution. It
          # used to run FIRST in this arm, ahead of `#{c[:args_struct]}::
          # from_json`, which is what BUG#23's standalone `structural_
          # precheck` splice, BUG#38/#136's discarded `_args_precheck`
          # and BUG#54's `collision_fallback` were each patching around,
          # one command shape at a time: a malformed identity argument
          # short-circuited into `NotFound` before the argument that was
          # unknown, absent, or ill-typed was ever judged. With the gates
          # running first, unconditionally, all three patches are gone —
          # `collision_key`'s aggregate-identity/argument wire-key
          # collision included, since `normalize_args` now always types
          # every declared attribute before this line is reached.
          id_line =
            if c[:creates]
              nil
            else
              "let id = match route { Some(route) => route.aggregate().to_string(), None => #{mod_path}::#{a[:record]}::extract_id(facts_json).map_err(|_| #{not_found_expr})?, };"
            end
          # THE ARGUMENT GATES, HANDED TO THE KERNEL (roadmap D2) — one
          # generated function per declared argument-gate step, called by
          # `kernel::decode_aggregate_arguments` in `AggregateStep::ORDER`
          # (dispatch.rs). This arm no longer decides which of them wins:
          # reordering `refuse_unknown_arguments`/`refuse_absent_
          # arguments`/`normalize_args`/`refuse_role_mismatch`/`resolve_
          # references` in vocabulary.bluebook reorders the refusals with
          # no change here at all, which is the whole point — the old
          # shape spelled that order out three times over (the standalone
          # `structural_precheck` splice, the preamble inside `from_json`,
          # and the physical order of the emitted lines).
          #
          # `refuse_role_mismatch`/`resolve_references` are closures
          # rather than plain function references because they need
          # `store` (every OTHER aggregate's own repo) — the same reason
          # `owner_deref`/`command_deref` below are computed at this
          # router level instead of inside the generated `dispatch_*`
          # function. They are done borrowing it well before `dispatch_
          # call` takes its own `&mut`.
          gates_expr = "crate::kernel::decode_aggregate_arguments(facts_json, &#{emit_argument_gates_literal("#{mod_path}::#{c[:args_struct]}", c[:invariant_check_lines], emit_role_check(c[:role], c[:name]), c[:reference_checks].map { |check| emit_reference_check(check) })})?"
          # BUG#141/BUG#123 — see `route_precheck_line`'s own header,
          # above, for the full reasoning. A single `if invocation.
          # explicit_with() { ... } else { ... }` EXPRESSION (its value
          # bound to `args`) rather than two separately-ordered
          # statements, so exactly one of the two orders ever actually
          # runs per call — never both, never a redundant second route
          # check.
          args_line =
            "let args = if invocation.explicit_with() { let args = #{gates_expr}; #{route_precheck_line} args } " \
            "else { #{route_precheck_line} #{gates_expr} };"
          # ANGLE-8's write-side tenant boundary (PR #595) — COMPUTED right
          # after the plain existence checks above, matching Ruby's own
          # `resolve_state_references` order (`validate_reference_values`
          # then `enforce_tenant_boundary`, per attribute) — it needs
          # `store` (every OTHER aggregate's own repo, to look up the
          # referenced record's own tenant field), the same reason `owner_
          # deref`/`command_deref` below are computed at this router level
          # rather than inside the generated `dispatch_*` function itself.
          #
          # BUG#139 — no longer APPLIED here, though: each individual
          # check's own `return Err(...)` used to fire the instant this
          # line ran, well before `hydrate`/`givens`/`mutations`/`ensures`/
          # `invariants` ever got their own say — inverting Ruby's real
          # `step_save`-time position (`CommandInterpreter#step_save`,
          # read directly: `resolve_state_references` runs before `seed_
          # projected_fields`/`persist_instance`, but AFTER every earlier
          # `DISPATCH_ORDER` step has already run to completion). Each
          # check's own body (`emit_tenant_boundary_check`, below — itself
          # UNCHANGED, still a `return Err(...)` on violation) is now
          # wrapped in an immediately-invoked closure instead: `return`
          # inside a closure returns from the CLOSURE, not this match arm,
          # so the RESULT (`Ok(())`, or the FIRST violation found — the
          # same short-circuit Ruby's own `.each { ... raise ... }` gives)
          # is captured as a plain owned value and handed to `dispatch_
          # call`'s own new trailing argument (this file's own comment on
          # that line), applied by `kernel::dispatch()` at the exact
          # deferred point Ruby's own `resolve_state_references` occupies
          # (`kernel/dispatch.rs`'s own header comment on the `tenant_
          # boundary_check` parameter has the full story). `[]` for every
          # command outside `tenant_ledger` today — `tenant_boundary_
          # checks`'s own header has the full argument — so `Ok(())`
          # unconditionally for every one of them, zero behavior change
          # from before this fix for any command that isn't `TenantLedger
          # ::Transfer.Request`.
          tenant_boundary_check_bodies = Array(c[:tenant_boundary_checks]).map { |check| emit_tenant_boundary_check(check) }
          tenant_boundary_check_line =
            if tenant_boundary_check_bodies.empty?
              "let tenant_boundary_check: Result<(), crate::kernel::Refusal> = Ok(());"
            else
              "let tenant_boundary_check: Result<(), crate::kernel::Refusal> = " \
                "(|| -> Result<(), crate::kernel::Refusal> { #{tenant_boundary_check_bodies.join(' ')} Ok(()) })();"
            end

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
                  args_line,
                  # IDENTITY AFTER THE GATES — `id_line`'s own comment,
                  # above; `extra_lines` reads a creating command's bare
                  # identity-extra heads, identity too, so it moves with it.
                  id_line, *extra_lines, tenant_boundary_check_line,
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
          # THE ARGUMENT GATES (roadmap D2) — see `registry_commands`'
          # own `gates_line`, above, for the whole argument;
          # `kernel::decode_entity_arguments` walks `EntityStep::ORDER`.
          gates_line = "let args = crate::kernel::decode_entity_arguments(facts_json, &#{emit_argument_gates_literal("#{mod_path}::#{c[:args_struct]}", c[:invariant_check_lines], emit_role_check(c[:role], c[:name]), c[:reference_checks].map { |check| emit_reference_check(check) })})?;"
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
          # ARGUMENT GATES BEFORE IDENTITY (roadmap D2) — this arm used to
          # splice a standalone `structural_precheck` and a discarded
          # `_args_precheck` INSIDE the route-less `None` branch, to beat
          # the two `extract_id` calls below (BUG#38, BUG#136). Both are
          # gone: `gates_line` above runs every declared argument gate,
          # for a routed and an unrouted call alike, and identity is only
          # resolved afterwards — which is Ruby's own order (`normalize_
          # args` precedes `hydrate_parent`/`locate_element`).
          #
          # The eager `route.require_depth(1)?` that now leads the body
          # keeps the ONE ordering that fix had to respect: Ruby resolves
          # an EXPLICITLY given `to:` in `Invocation.route`, entirely
          # independently of `facts`, so a wrong-depth route refuses
          # `TypeMismatch` on its own terms before any argument gate.
          # BUG#132 (qa/bluebook/quality_control.bluebook) — the SAME
          # BUG#20 fix the aggregate arm's own `id_line` already applies
          # (this file's header, above: wrap `extract_id`'s raw `Err`
          # into the exact `NotFound` wording Ruby's own identity-
          # resolution failure produces) had never been extended to this,
          # the ENTITY arm's route-less `None` branch — both `parent_id`
          # and `element_id` here still let `extract_id`'s own bare
          # `TypeMismatch` propagate via a plain `?`, diverging from
          # Ruby's own `EntityInterpreter#parent` (raises `NotFound`/
          # `entity_parent_no_identity` when the PARENT aggregate's
          # identity can't be read off `args` at all — entity_
          # interpreter.rb, read directly) and `EntityElement#element_of`
          # (raises `NotFound`/`entity_element_no_identity` when the
          # ELEMENT's own identity is absent — entity_element.rb).
          # Confirmed live: `Roster::Roster.Member.Retire` with a
          # genuinely empty `args: {}` — `Member.Retire`'s own `id` is
          # declared `optional: true` (line 100 of examples/roster/
          # bluebook/roster.bluebook, not a routing source — an entity's
          # own identity is always read off `extract_id`/route, never
          # this optional echo argument), so the argument gates
          # (unknown/absent-argument names only, for this shape) all pass
          # and both `extract_id` calls run on a clean payload. Ruby
          # refuses `NotFound` ("Retire acts on a Roster's Member — pass
          # name.value:"); Rust refused `TypeMismatch` ("Roster: no
          # identity found (tried name.value, id, roster)") instead — a
          # DIFFERENT gap than BUG#38/#126 (both about the argument
          # gates' own PLACEMENT relative to `extract_id`, an
          # argument-existence-check ordering issue, since settled by
          # roadmap D2): here every gate passes cleanly (nothing IS
          # unknown or absent-required), and it is `extract_id`'s own
          # failure that was never
          # wrapped for this arm at all — roster's committed Rust output
          # was not stale (byte-identical to what `bin/project_rust
          # examples/roster` produces on this same commit; roster is
          # already in `.github/workflows/ci-checks.yml`'s regen list).
          entity_parent_no_identity_message = "#{c[:name]} acts on a #{a[:record]}'s #{c[:entity_name]} — pass #{Array(a[:identified_by]).join(', ')}:"
          entity_element_no_identity_message = "#{c[:name]} acts on one #{c[:entity_name]} — pass #{c[:entity_identity_reading]}:"
          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let route = invocation.route();",
                  "let facts_json = invocation.facts();",
                  # BUG#140 — `element_id` now resolves through `extract_
                  # id_lenient` (json_codec.rb's own header), not the
                  # strict `extract_id`: `EntityElement#element_of`'s own
                  # `raw = args[head] || raise(...)` only ever refuses a
                  # genuinely ABSENT identity key (still wrapped into
                  # `entity_element_no_identity` below, via the SAME
                  # `map_err`, when the lenient extraction itself fails),
                  # never a present-but-blank one. A present, blank
                  # element identity now flows through as an ordinary
                  # (non-matching) `element_id`, and `dispatch_entity`'s
                  # own `apply_entity_command` (kernel/dispatch.rs) —
                  # unchanged — already renders the correct `entity_
                  # element_missing` wording once no stored element's own
                  # `identity()` equals it. `parent_id` stays on the
                  # STRICT `extract_id` — a ROOT aggregate's own identity
                  # (`to_id_component_lenient`'s own header explains why).
                  "if let Some(route) = route { route.require_depth(1)?; }",
                  gates_line,
                  "let (parent_id, element_id, element_wants) = match route { Some(route) => { let element_id = route.entities()[0].clone(); (route.aggregate().to_string(), element_id.clone(), element_id) }, None => { let parent_id = #{mod_path}::#{a[:record]}::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound(#{entity_parent_no_identity_message.inspect}.to_string()))?; let element_id = #{mod_path}::#{c[:entity_record]}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound(#{entity_element_no_identity_message.inspect}.to_string()))?; let element_wants = #{mod_path}::#{c[:entity_record]}::extract_wants(facts_json); (parent_id, element_id, element_wants) }, };",
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
          # THE ARGUMENT GATES (roadmap D2) — see `registry_commands`'
          # own `gates_line`, above, for the whole argument;
          # `kernel::decode_entity_arguments` walks `EntityStep::ORDER`.
          gates_line = "let args = crate::kernel::decode_entity_arguments(facts_json, &#{emit_argument_gates_literal("#{mod_path}::#{c[:args_struct]}", c[:invariant_check_lines], emit_role_check(c[:role], c[:name]), c[:reference_checks].map { |check| emit_reference_check(check) })})?;"
          dispatch_call = "#{mod_path}::dispatch_entity_#{c[:fn]}(&mut store.#{a[:mod]}, &parent_id, &hop1_id, &hop1_wants, &hop2_id, &hop2_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))"

          # ARGUMENT GATES BEFORE IDENTITY (roadmap D2) — see the one-hop
          # `entity_arms`' own identical note, above: no standalone
          # precheck and no discarded `_args_precheck` any more, and the
          # eager `route.require_depth(2)?` keeps an explicit wrong-depth
          # route refusing ahead of them all.
          # BUG#132 — see `entity_arms`'s own identical fix, above: the
          # SAME unwrapped `extract_id(facts_json)?` gap, one nesting hop
          # deeper. `parent_id` wraps into `entity_parent_no_identity`
          # (Ruby's `EntityInterpreter#parent`, joined entity path —
          # `ctx.entity_name` there is `entity_names.join(".")`, matching
          # `"#{c[:entity_name]}.#{c[:nested_name]}"` here); `hop1_id`/
          # `hop2_id` each wrap into their OWN hop's `entity_element_no_
          # identity` (Ruby's `EntityElement#element_of` runs once per
          # chain entry — `locate_chain`, entity_element.rb — so each
          # hop's failure names THAT hop's own entity/identity, never the
          # other's).
          entity_parent_no_identity_message = "#{c[:name]} acts on a #{a[:record]}'s #{c[:entity_name]}.#{c[:nested_name]} — pass #{Array(a[:identified_by]).join(', ')}:"
          hop1_no_identity_message = "#{c[:name]} acts on one #{c[:entity_name]} — pass #{c[:entity_identity_reading]}:"
          hop2_no_identity_message = "#{c[:name]} acts on one #{c[:nested_name]} — pass #{c[:nested_identity_reading]}:"
          # BUG#140 — `hop1_id`/`hop2_id` both now resolve through
          # `extract_id_lenient`, not `extract_id`: `EntityElement#
          # locate_chain` runs `element_of` once per chain entry
          # (entity_element.rb), and EVERY hop shares the identical
          # "absent key raises, present-but-blank flows through as a
          # merely non-matching value" rule — `entity_arms`' own identical
          # comment, above, has the full reasoning. `parent_id` stays on
          # the strict `extract_id`.
          route_binding =
            if c[:unrouted_supported]
              "let (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) = match route { Some(route) => { let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); (route.aggregate().to_string(), hop1_id.clone(), hop1_id, hop2_id.clone(), hop2_id) }, None => { let parent_id = #{mod_path}::#{a[:record]}::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound(#{entity_parent_no_identity_message.inspect}.to_string()))?; let hop1_id = #{mod_path}::#{c[:entity_record]}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound(#{hop1_no_identity_message.inspect}.to_string()))?; let hop1_wants = #{mod_path}::#{c[:entity_record]}::extract_wants(facts_json); let hop2_id = #{mod_path}::#{c[:nested_record]}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound(#{hop2_no_identity_message.inspect}.to_string()))?; let hop2_wants = #{mod_path}::#{c[:nested_record]}::extract_wants(facts_json); (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) }, };"
            else
              "let route = route.ok_or_else(|| crate::kernel::Refusal::TypeMismatch(#{"#{c[:verb]} addresses an entity nested two levels deep — requires an explicit to: { aggregate:, entities: [...] } route".inspect}.to_string()))?; let parent_id = route.aggregate().to_string(); let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); let hop1_wants = hop1_id.clone(); let hop2_wants = hop2_id.clone();"
            end

          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let route = invocation.route();",
                  "let facts_json = invocation.facts();",
                  "if let Some(route) = route { route.require_depth(2)?; }",
                  gates_line,
                  route_binding,
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
