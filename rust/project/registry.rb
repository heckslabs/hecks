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

          dispatch_call = "#{mod_path}::dispatch_#{c[:fn]}(&mut store.#{a[:mod]}, #{c[:creates] ? extra_pass : '&id, '}args, mutations, owner_deref, command_deref)"
          # ROUTING SEPARATION (`to:`/`with:`) — `CommandInvocation` reads
          # either the explicit routed/facts shape or the legacy mixed-
          # args object (rust/src/kernel/routing.rs, this file's own
          # target). An ACTING command's own `id` comes from the route
          # when one was given (`route.require_depth(0)?` — an aggregate-
          # level command addresses no entity), falling back to `extract_
          # id` against `facts_json` for the legacy shape, matching
          # `CommandInterpreter#hydrate_existing`'s own `route ||
          # identity_of(...)` order exactly.
          id_line = c[:creates] ? "" : "let id = match route { Some(route) => { route.require_depth(0)?; route.aggregate().to_string() }, None => #{mod_path}::#{a[:record]}::extract_id(facts_json)?, };"
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
                  id_line, *extra_lines, "let args = #{mod_path}::#{c[:args_struct]}::from_json(facts_json)?;", role_line, *reference_lines,
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
          # `owner_deref` is always empty here — a REAL, DOCUMENTED gap,
          # not an oversight: an entity's OWN `reference_to` attributes
          # (dereferenced off the addressed ELEMENT itself, distinct from
          # `command_deref`'s `"parent"` entry below) would need this
          # router to find the parent AND match the one addressed element
          # BEFORE `dispatch_entity` itself does — the exact "parent"/
          # "element" lookup `kernel::dispatch_entity` already owns
          # internally. No entity in this corpus declares a reference-typed
          # attribute of its own (confirmed against the real IR, not
          # assumed), so nothing here is silently wrong today; a future
          # entity that does would need this router taught the same
          # peek-before-dispatch fetch `owner_deref` above already does
          # for an aggregate.
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
          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let route = invocation.route();",
                  "let facts_json = invocation.facts();",
                  "let (parent_id, element_id, element_wants) = match route { Some(route) => { route.require_depth(1)?; let element_id = route.entities()[0].clone(); (route.aggregate().to_string(), element_id.clone(), element_id) }, None => { let parent_id = #{mod_path}::#{a[:record]}::extract_id(facts_json)?; let element_id = #{mod_path}::#{c[:entity_record]}::extract_id(facts_json)?; let element_wants = #{mod_path}::#{c[:entity_record]}::extract_wants(facts_json); (parent_id, element_id, element_wants) }, };",
                  "let args = #{mod_path}::#{c[:args_struct]}::from_json(facts_json)?;",
                  role_line, *reference_lines,
                  "let owner_deref: Vec<(&'static str, crate::kernel::DerefNode)> = Vec::new();",
                  "let mut command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, #{emit_reference_specs_literal(c[:reference_specs])}, &args);",
                  "if let Some(parent_node) = crate::kernel::parent_deref(&*store, REFERENCE_TABLE, #{"#{a[:domain_name]}::#{a[:name]}".inspect}, &parent_id) { command_deref.push((\"parent\", parent_node)); }",
                  "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());",
                  dispatch_call].compact

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
          dispatch_call = "#{mod_path}::dispatch_operation_#{p[:fn]}(&id, args).map(|events| stamp_payload(events, &payload))"

          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let (id, port_facts) = invocation.split_aggregate_receiver(#{legacy_receiver})?;",
                  "let facts_json = &port_facts;",
                  "let _instance = store.#{a[:mod]}.find(&id).ok_or_else(|| crate::kernel::Refusal::NotFound(format!(\"#{a[:name]} {:?} does not exist\", id)))?;",
                  "let args = #{mod_path}::#{p[:args_struct]}::from_json(facts_json)?;", *reference_lines,
                  "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());",
                  dispatch_call].compact

          "          #{p[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      dispatch_arms = aggregate_arms + entity_arms + port_arms

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
