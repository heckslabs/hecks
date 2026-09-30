# Emits the generated Rust registry and JSON command router for a projected domain.
module RustProjection
  module Projector
    module_function

    # Statement refusing a caller whose role differs from the command's declared `role:`.
    # Emitted at router level, where the caller's role arrives as `caller_role`.
    # `command_name` is the short name ("Open"), matching Ruby's refusal wording.
    def emit_role_check(role, command_name)
      return nil unless role

      Exemplar.render("role_check", '"TmplRole"' => role.inspect, '"TmplCommandName"' => command_name.to_s.inspect)
    end

    # The `kernel::ArgumentGates` literal for one command, consumed by
    # `decode_aggregate_arguments`/`decode_entity_arguments`, which own the step order.
    # Role and reference checks are closures because they need `store`.
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

    # Collapses a multi-line emitted statement to one line so it can sit in a closure.
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

    # Rust statement refusing a cross-tenant reference (`check` is built by
    # `tenant_boundary_checks` in domain_generator.rb). Hand-built, not an Exemplar: the target
    # accessor is either a single-attribute value object or a bare scalar, which the fixed
    # reference_check_* templates have no slot for. `{:?}` matches Ruby's `#inspect` for both.
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

    # Builds registry.rs: `Store`, `instances()`, `from_seed`, the query lookup and the JSON
    # command router. `aggregates` is accumulated by domain_generator.rb. Paths are absolute
    # (`crate::generated::<chapter>::<mod>`) so single- and multi-chapter callers resolve alike;
    # `domain_name` is read per aggregate so a merged registry labels each dump correctly.
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

      # Inverse of `instances()`: one `if let` per aggregate on its "Domain::Aggregate#" prefix.
      # Unrecognized seed keys are skipped, not refused, so a host can seed loosely.
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

      # Query lookup: one `if` per aggregate on the bare "Domain::Aggregate" prefix (no "#";
      # the whole string names one aggregate). Called by the "query" step in kernel/cli.rs.
      query_arms = aggregates.map do |a|
        prefix = "#{a[:domain_name]}::#{a[:name]}"
        <<~RUST.rstrip
                  if aggregate == #{prefix.inspect} {
                      return Some(self.#{a[:mod]}.json_entries(|record| record.to_json()).map(|(id, json)| (id.clone(), json.clone())).collect());
                  }
        RUST
      end

      # Borrowed twin of `query_arms`: the same prefixes, visiting each cached row in place.
      scan_each_arms = aggregates.map do |a|
        prefix = "#{a[:domain_name]}::#{a[:name]}"
        <<~RUST.rstrip
                  if aggregate == #{prefix.inspect} {
                      for (id, json) in self.#{a[:mod]}.json_entries(|record| record.to_json()) {
                          visit(id, json);
                      }
                      return true;
                  }
        RUST
      end

      aggregate_arms = aggregates.flat_map do |a|
        mod_path = chapter_path.call(a)
        a[:commands].map do |c|
          # Identity extras (bare `identified_by` heads that are not attributes) are read from
          # `facts_json`: no
          # typed struct carries — then passed positionally into
          # `dispatch_call` in commands.rb's `fn_signature` order. Absent is `NotFound`.
          extra_names  = Array(c[:identity_extra_params])
          extra_idents = extra_names.map { |name| rust_ident_field(name) }
          extra_lines  = extra_names.zip(extra_idents).map do |name, ident|
            "let #{ident} = facts_json.dig(#{name.to_s.inspect}).ok_or_else(|| crate::kernel::Refusal::NotFound(#{"#{c[:verb]} creates a #{a[:record]} — pass #{name}".inspect}.to_string()))?.to_id_component()?;"
          end
          extra_pass = extra_idents.map { |ident| "&#{ident}, " }.join

          # A creating command's `dispatch_*` takes `route` right after `repo`.
          # `tenant_boundary_check` is computed eagerly here and applied deferred in `dispatch()`.
          dispatch_call = "#{mod_path}::dispatch_#{c[:fn]}(&mut store.#{a[:mod]}, #{c[:creates] ? "route, #{extra_pass}" : '&id, '}args, mutations, owner_deref, command_deref, tenant_boundary_check)"
          # The route supplies an acting command's `id`; otherwise `extract_id` reads `facts_json`.
          # A wholly missing identity is `NotFound` (acting_no_identity), as in `hydrate_existing`;
          # `render_args` keeps the wording declared in one place.
          acting_no_identity_args =
            "crate::kernel::refusal_wording::NotFoundActingNoIdentityArgs { " \
            "command: #{c[:name].to_s.inspect}, aggregate: #{a[:record].to_s.inspect}, " \
            "identity: #{Array(a[:identified_by]).join(', ').inspect} }.render_args()"
          # Route depth is checked before the argument gates for a flat-facts call and after them
          # for an explicit `with:` call, as in Ruby's `Invocation.from_call`. A fixed order
          # either way regressed, so `explicit_with()` picks the order per call.
          route_precheck_line = "if let Some(route) = route { route.require_depth(0)?; }"
          not_found_expr = "crate::kernel::Refusal::NotFound(#{acting_no_identity_args})"
          # Identity resolution runs after every argument gate, as Ruby's `step_hydrate` does, so a
          # malformed identity never masks an unknown, absent or ill-typed argument.
          id_line =
            if c[:creates]
              nil
            else
              "let id = match route { Some(route) => route.aggregate().to_string(), None => #{mod_path}::#{a[:record]}::extract_id(facts_json).map_err(|_| #{not_found_expr})?, };"
            end
          # The kernel runs the argument gates in `AggregateStep::ORDER`; this arm does not.
          # Role and reference checks are closures because they need `store`, and they finish
          # borrowing it before `dispatch_call` takes its `&mut`.
          gates_expr = "crate::kernel::decode_aggregate_arguments(facts_json, &#{emit_argument_gates_literal("#{mod_path}::#{c[:args_struct]}", c[:invariant_check_lines], emit_role_check(c[:role], c[:name]), c[:reference_checks].map { |check| emit_reference_check(check) })})?"
          # One if/else expression, so exactly one route-check order runs per call.
          args_line =
            "let args = if invocation.explicit_with() { let args = #{gates_expr}; #{route_precheck_line} args } " \
            "else { #{route_precheck_line} #{gates_expr} };"
          # Computed here because it needs `store`; applied deferred by `kernel::dispatch()` where
          # Ruby's `resolve_state_references` runs, after every earlier dispatch step. Each check's
          # `return Err(...)` sits in a closure so the first violation is captured as a value.
          tenant_boundary_check_bodies = Array(c[:tenant_boundary_checks]).map { |check| emit_tenant_boundary_check(check) }
          tenant_boundary_check_line =
            if tenant_boundary_check_bodies.empty?
              "let tenant_boundary_check: Result<(), crate::kernel::Refusal> = Ok(());"
            else
              "let tenant_boundary_check: Result<(), crate::kernel::Refusal> = " \
                "(|| -> Result<(), crate::kernel::Refusal> { #{tenant_boundary_check_bodies.join(' ')} Ok(()) })();"
            end

          # `given`/`ensures` cross-aggregate dereference is resolved here because it needs `store`
          # and must end its borrow before the `&mut store.<mod>` in the dispatch call. A creating
          # command has no record yet, so `owner_deref` is empty; `command_deref` covers it.
          owner_deref_expr = c[:creates] ? "Vec::new()" : "crate::kernel::owner_deref(&*store, REFERENCE_TABLE, #{"#{a[:domain_name]}::#{a[:name]}".inspect}, &id)"
          deref_lines = [
            "let owner_deref = #{owner_deref_expr};",
            "let command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, #{emit_reference_specs_literal(c[:reference_specs])}, &args);",
          ]

          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let route = invocation.route();",
                  "let facts_json = invocation.facts();",
                  args_line,
                  # Identity resolves after the gates; identity extras are read with it.
                  id_line, *extra_lines, tenant_boundary_check_line,
                  *deref_lines,
                  "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());",
                  "#{dispatch_call}.map(|(_, events)| stamp_payload(events, &payload))"].compact.reject(&:empty?)

          "          #{c[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      # Entity commands never create: parent and element identity are both read from the raw
      # JSON. The generated function is `dispatch_entity_<fn>`.
      entity_arms = aggregates.flat_map do |a|
        mod_path = chapter_path.call(a)
        a[:entity_commands].map do |c|
          # Argument gates: see `aggregate_arms`; `decode_entity_arguments` walks
          # `EntityStep::ORDER`.
          gates_line = "let args = crate::kernel::decode_entity_arguments(facts_json, &#{emit_argument_gates_literal("#{mod_path}::#{c[:args_struct]}", c[:invariant_check_lines], emit_role_check(c[:role], c[:name]), c[:reference_checks].map { |check| emit_reference_check(check) })})?;"
          dispatch_call = "#{mod_path}::dispatch_entity_#{c[:fn]}(&mut store.#{a[:mod]}, &parent_id, &element_id, &element_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))"

          # `element_wants` is the caller-offered scalar identity values (`emit_extract_wants`),
          # computed unconditionally alongside `element_id`.
          # `owner_deref` is taken off `parent_id`, like an aggregate `Act`, so re-seeded parent
          # `projects` fields resolve; `command_deref` also gets a "parent" node for `parent.X`
          # givens.
          # An entity's own reference attributes are not dereferenced (none in the corpus has one).
          # An explicit route addresses one entity (`require_depth(1)`) and is checked ahead of the
          # argument gates, as Ruby resolves `to:` independently of facts; unrouted calls fall back
          # to `extract_id`/`extract_wants`. A failed `extract_id` becomes Ruby's NotFound wording
          # (entity_parent_no_identity, entity_element_no_identity), not `TypeMismatch`.
          entity_parent_no_identity_message = "#{c[:name]} acts on a #{a[:record]}'s #{c[:entity_name]} — pass #{Array(a[:identified_by]).join(', ')}:"
          entity_element_no_identity_message = "#{c[:name]} acts on one #{c[:entity_name]} — pass #{c[:entity_identity_reading]}:"
          body = ["let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;",
                  "let route = invocation.route();",
                  "let facts_json = invocation.facts();",
                  # `element_id` uses `extract_id_lenient`: only an absent identity key is refused;
                  # a blank one flows through as a non-matching id. `parent_id` stays strict.
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

      # Commands owned by an entity nested two levels deep
      # (`dispatch_entity_<entity>_<nested>_<fn>`). With `c[:unrouted_supported]` the arm mirrors
      # `entity_arms` one hop deeper; otherwise it requires an explicit route (`require_depth(2)`).
      nested_entity_arms = aggregates.flat_map do |a|
        mod_path = chapter_path.call(a)
        Array(a[:nested_entity_commands]).map do |c|
          # Argument gates: see `aggregate_arms`; `decode_entity_arguments` walks
          # `EntityStep::ORDER`.
          gates_line = "let args = crate::kernel::decode_entity_arguments(facts_json, &#{emit_argument_gates_literal("#{mod_path}::#{c[:args_struct]}", c[:invariant_check_lines], emit_role_check(c[:role], c[:name]), c[:reference_checks].map { |check| emit_reference_check(check) })})?;"
          dispatch_call = "#{mod_path}::dispatch_entity_#{c[:fn]}(&mut store.#{a[:mod]}, &parent_id, &hop1_id, &hop1_wants, &hop2_id, &hop2_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))"

          # Gates run before identity and the depth check leads, as in `entity_arms`. A failed
          # `extract_id` per hop becomes that hop's own NotFound wording, as in `locate_chain`;
          # the parent uses the joined entity path.
          entity_parent_no_identity_message = "#{c[:name]} acts on a #{a[:record]}'s #{c[:entity_name]}.#{c[:nested_name]} — pass #{Array(a[:identified_by]).join(', ')}:"
          hop1_no_identity_message = "#{c[:name]} acts on one #{c[:entity_name]} — pass #{c[:entity_identity_reading]}:"
          hop2_no_identity_message = "#{c[:name]} acts on one #{c[:nested_name]} — pass #{c[:nested_identity_reading]}:"
          # Every hop uses `extract_id_lenient` (see `entity_arms`); `parent_id` stays strict.
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
                  # `owner_deref` uses the top-level aggregate's reference fields.
                  "let owner_deref = crate::kernel::owner_deref(&*store, REFERENCE_TABLE, #{"#{a[:domain_name]}::#{a[:name]}".inspect}, &parent_id);",
                  "let command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, #{emit_reference_specs_literal(c[:reference_specs])}, &args);",
                  "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());",
                  dispatch_call].compact.reject(&:empty?)

          "          #{c[:verb].inspect} => {\n#{body.map { |line| "              #{line}" }.join("\n")}\n          }"
        end
      end

      # Port operations: a command arm without `creates` or a role check (a port has no caller
      # role). Reference checks are emitted here because they need `store`. The receiver comes from
      # the route or `legacy_receiver_field` and is stripped from the facts `from_json` sees; its
      # existence is checked once here.
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
        "tmpl_scan_each_arm_placeholder();" => scan_each_arms.join("\n"),
        '"tmpl_verb" => { tmpl_dispatch_arm_placeholder() }' => dispatch_arms.join("\n")
      )

      "#{header}#{body}"
    end

    # The domain-wide `REFERENCE_TABLE` plus `Store`'s `ReferenceLookup` impl, which needs
    # `store` to fetch targets. One row per aggregate, from `a[:reference_specs]`.
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

    # `find_fielded`: one `if` per aggregate, boxing the found record as a type-erased
    # `Fielded`. An undeclared or ungenerated target (e.g. cross-domain) yields `None`.
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
