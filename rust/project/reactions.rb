module RustProjection
  module Projector
    module_function

    # Re-derives event_qualifier/event_name from on_event the same way
    # Policy#event_qualifier/#event_name do — the wire only carries on_event whole.
    def policy_event_qualifier(on_event)
      text = on_event.to_s
      text.include?(".") ? text.split(".", 2).first : nil
    end

    def policy_event_name(on_event)
      text = on_event.to_s
      text.include?(".") ? text.split(".", 2).last : text
    end

    # Emits PolicyRule rows for policies targeting domain_name only; a policy
    # targeting another domain routes through emit_cross_domain_policy_table.
    def emit_policy_table(domain_name, policies, aggregates = [])
      fns  = where_fns(policies)
      rows = local_policy_rows(domain_name, policies, aggregates)

      Exemplar.render(
        "policy_table",
        'crate::kernel::PolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_verb: "tmpl_target_verb", for_each: None, for_each_key: None, with_spec: &[], where_expr: None },' => rows.join("\n")
      ).then { |table| fns.empty? ? table : "#{table}\n\n#{fns.join("\n\n")}" }
    end

    # Merges policy rows across the target domain and every attached chapter;
    # each source is qualified against its own domain_name/aggregates.
    def emit_merged_policy_table(sources)
      rows = sources.flat_map { |source| local_policy_rows(source[:domain_name], source[:policies], source[:aggregates]) }
      fns  = sources.flat_map { |source| where_fns(source[:policies]) }

      Exemplar.render(
        "policy_table",
        'crate::kernel::PolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_verb: "tmpl_target_verb", for_each: None, for_each_key: None, with_spec: &[], where_expr: None },' => rows.join("\n")
      ).then { |table| fns.empty? ? table : "#{table}\n\n#{fns.join("\n\n")}" }
    end

    def local_policy_rows(domain_name, policies, aggregates = [])
      policies.filter_map do |policy|
        target_domain = policy[:target_domain] || domain_name
        next nil unless target_domain == domain_name

        event_name = policy_event_name(policy[:on_event])
        qualifier = policy_event_qualifier(policy[:on_event])
        qualifier_expr = qualifier ? "Some(#{qualifier.inspect})" : "None"
        target_verb = "#{target_domain}::#{policy[:trigger_command]}"

        # policy_name lets orchestrate.rs's reaction_log/saga_log name the
        # policy that fired, matching what CrossDomainPolicyRule already carries.
        "    crate::kernel::PolicyRule { policy_name: #{policy[:name].to_s.inspect}, event_name: #{event_name.inspect}, " \
          "event_qualifier: #{qualifier_expr}, target_verb: #{target_verb.inspect}, " \
          "for_each: #{fan_out_verb_expr(domain_name, policy)}, " \
          "for_each_key: #{fan_out_key_expr(domain_name, policy, aggregates)}, " \
          "with_spec: #{with_spec_expr(policy)}, where_expr: #{where_expr(policy)} },"
      end
    end

    # where_expr is a generated function, not a literal: PolicyRule is a const
    # row but Expr owns boxes, so a where { ... } predicate compiles to a callback.
    def where_fn_name(policy) = "where_#{dispatch_fn_name(rust_ident(policy[:name].to_s))}"

    def where_expr(policy)
      policy[:where].to_s.empty? ? "None" : "Some(#{where_fn_name(policy)})"
    end

    def where_fns(policies)
      policies.reject { |policy| policy[:where].to_s.empty? }.map do |policy|
        "fn #{where_fn_name(policy)}() -> crate::kernel::Expr {\n" \
          "    use crate::kernel::Expr;\n" \
          "    #{ExprEmitter.emit_ast(policy[:where_ast])}\n" \
          "}"
      end
    end

    # Resolves a bare "Aggregate.query" for_each spelling against the policy's
    # own domain here, so the kernel's own lookup stays a plain table hit.
    def fan_out_verb_expr(domain_name, policy)
      for_each = policy[:for_each].to_s
      return "None" if for_each.empty?

      "Some(#{(for_each.include?("::") ? for_each : "#{domain_name}::#{for_each}").inspect})"
    end

    # Addressing key: a command declared on the aggregate it references uses
    # its bare reference key; one merely holding a reference uses that attribute.
    def fan_out_key_expr(domain_name, policy, aggregates)
      for_each = policy[:for_each].to_s
      return "None" if for_each.empty?

      path, = for_each.split(".", 2)
      row_aggregate = path.to_s.include?("::") ? path.split("::", 2).last : path
      command = target_command_for(policy, aggregates)
      key = command && addressing_key_for(command, row_aggregate)
      key ? "Some(#{key.to_s.inspect})" : "None"
    end

    def target_command_for(policy, aggregates)
      aggregate_name, command_name = policy[:trigger_command].to_s.split(".", 2)
      aggregate = Array(aggregates).find { |candidate| candidate[:name].to_s == aggregate_name.to_s }
      Array(aggregate && aggregate[:commands]).find { |candidate| candidate[:name].to_s == command_name.to_s }
    end

    def addressing_key_for(command, aggregate_name)
      return snake_case(aggregate_name) if command[:references].to_s == aggregate_name.to_s

      held = Array(command[:attributes]).find { |attribute| attribute[:type].to_s == "Reference<#{aggregate_name}>" }
      held && held[:name]
    end

    def snake_case(name)
      name.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2').downcase
    end

    # Each binding rides the wire already rendered (Literal::render, so a
    # Symbol keeps its leading colon and stays distinct from a same-spelled string).
    def with_spec_expr(policy)
      pairs = Array(policy[:with_spec])
      return "&[]" if pairs.empty?

      "&[#{pairs.map { |key, value| "(#{key.to_s.inspect}, #{value.to_s.inspect})" }.join(', ')}]"
    end

    # target_verb is always fully qualified ("Domain::Aggregate.Command") —
    # the same form dispatch_by_name and every cross-Lambda caller expect.
    def cross_domain_policy_rows(domain_name, policies)
      policies.filter_map do |policy|
        target_domain = policy[:target_domain] || domain_name
        next nil if target_domain == domain_name

        event_name = policy_event_name(policy[:on_event])
        qualifier = policy_event_qualifier(policy[:on_event])
        qualifier_expr = qualifier ? "Some(#{qualifier.inspect})" : "None"
        target_verb = "#{target_domain}::#{policy[:trigger_command]}"

        "    crate::kernel::CrossDomainPolicyRule { policy_name: #{policy[:name].to_s.inspect}, event_name: #{event_name.inspect}, " \
          "event_qualifier: #{qualifier_expr}, target_domain: #{target_domain.inspect}, target_verb: #{target_verb.inspect}, " \
          "where_expr: #{where_expr(policy)} },"
      end
    end

    def emit_cross_domain_policy_table(domain_name, policies)
      rows = cross_domain_policy_rows(domain_name, policies)

      puts "cross-domain policy table: #{rows.size} row(s) — delivered by rust/host's lambda_client.rs, not locally dispatched" if rows.any?

      Exemplar.render(
        "cross_domain_policy_table",
        'crate::kernel::CrossDomainPolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_domain: "tmpl_target_domain", target_verb: "tmpl_target_verb", where_expr: None },' =>
          rows.join("\n")
      )
    end

    # Merges cross-domain rows across every attached chapter the same way
    # emit_merged_policy_table merges local ones; aggregates are unused here.
    def emit_merged_cross_domain_policy_table(sources)
      rows = sources.flat_map { |source| cross_domain_policy_rows(source[:domain_name], source[:policies]) }

      puts "cross-domain policy table: #{rows.size} row(s) — delivered by rust/host's lambda_client.rs, not locally dispatched" if rows.any?

      Exemplar.render(
        "cross_domain_policy_table",
        'crate::kernel::CrossDomainPolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_domain: "tmpl_target_domain", target_verb: "tmpl_target_verb", where_expr: None },' =>
          rows.join("\n")
      )
    end

    # Reuses Marks.read (mutations.rb's append_field_source is the same round
    # trip) rather than re-deriving the with: literal's wire spelling.
    def with_value_parsed(raw)
      Hecks::Bluebook::Assembly::Marks.read(raw)
    end

    # Builds a Json value expression rather than a const literal: Json holds
    # Vec/String, which isn't const-constructible in stable Rust.
    def json_literal_expr(value)
      case value
      when Hash
        fields = value.map { |k, v| "(#{k.to_s.inspect}.to_string(), #{json_literal_expr(v)})" }
        "crate::kernel::Json::Object(vec![#{fields.join(', ')}])"
      when String
        "crate::kernel::Json::Str(#{value.inspect}.to_string())"
      when Integer
        "crate::kernel::Json::int(#{value})"
      when Float
        "crate::kernel::Json::Num(#{value}f64)"
      when true, false
        "crate::kernel::Json::Bool(#{value})"
      when nil
        "crate::kernel::Json::Null"
      else
        raise "unsupported with: literal #{value.inspect} — json_literal_expr doesn't cover this shape"
      end
    end

    # A bare Symbol is a runtime WithValue::Ref; anything else is a literal,
    # emitted as its own fn() -> Json collected into literal_fns.
    def emit_with_value(raw, literal_fns)
      parsed = with_value_parsed(raw)
      return "crate::kernel::WithValue::Ref(#{parsed.to_s.inspect})" if parsed.is_a?(Symbol)

      fn_name = "pm_literal_#{literal_fns.size}"
      literal_fns << Exemplar.render(
        "with_value_literal_fn",
        "tmpl_literal_fn" => fn_name,
        "tmpl_body_placeholder()" => json_literal_expr(parsed)
      )
      "crate::kernel::WithValue::Literal(#{fn_name})"
    end

    # compensates recurses into itself at most one level: a compensation is
    # never itself compensable.
    def emit_dispatch_spec(spec, literal_fns)
      with_pairs = spec[:with_spec].map { |key, raw| "(#{key.to_s.inspect}, #{emit_with_value(raw, literal_fns)})" }
      compensates = spec[:compensates] ? "Some(&#{emit_dispatch_spec(spec[:compensates], literal_fns)})" : "None"
      "crate::kernel::DispatchSpec { command_name: #{spec[:command_name].inspect}, with: &[#{with_pairs.join(', ')}], compensates: #{compensates} }"
    end

    def emit_handler(handler, literal_fns)
      dispatches = handler[:dispatches].map { |d| emit_dispatch_spec(d, literal_fns) }
      "crate::kernel::Handler { event_type: #{handler[:event_type].inspect}, from_state: #{handler[:from_state].inspect}, to_state: #{handler[:to_state].inspect}, dispatches: &[#{dispatches.join(', ')}] }"
    end

    # No cross-domain narrowing needed here the way emit_policy_table needs
    # one: every dispatch's command_name is already domain-qualified on the wire.
    def emit_process_manager_table(process_managers)
      literal_fns = []
      pm_exprs = process_managers.map do |pm|
        handlers = pm[:handlers].map { |h| emit_handler(h, literal_fns) }
        "crate::kernel::ProcessManagerDef { name: #{pm[:name].inspect}, correlates_by: #{pm[:correlates_by].inspect}, " \
          "starts_on: #{pm[:starts_on].inspect}, ends_on: #{pm[:ends_on].inspect}, initial_state: #{pm[:states].first.inspect}, " \
          "handlers: &[#{handlers.join(', ')}] }"
      end

      Exemplar.render(
        "process_manager_table",
        "fn tmpl_literal_fns_placeholder() {}" => literal_fns.join("\n"),
        '    crate::kernel::ProcessManagerDef { name: "tmpl_pm_name", correlates_by: "tmpl_correlates_by", starts_on: "tmpl_starts_on", ends_on: "tmpl_ends_on", initial_state: "tmpl_initial_state", handlers: &[] },' =>
          pm_exprs.map { |e| "    #{e}," }.join("\n")
      )
    end

    # Precomputes Naming.reference_key(event.aggregate) per aggregate for
    # kernel::orchestrate's correlation fallback, keyed by qualified aggregate name.
    def emit_reference_key_table(chapters)
      arms = chapters.flat_map do |domain_name, aggregate_names|
        aggregate_names.map do |name|
          qualified = "#{domain_name}::#{name}"
          key = Hecks::Naming.snake(name)
          "        #{qualified.inspect} => Some(#{key.inspect}),"
        end
      end

      Exemplar.render("reference_key_table", '"tmpl_qualified" => Some("tmpl_key"),' => arms.join("\n"))
    end

    # Whether a verb's dispatch creates its own record, needed before
    # orchestrate.rs's routing split can promote an addressing key into to:.
    def emit_creates_table(aggregates)
      arms = aggregates.flat_map do |aggregate|
        (Array(aggregate[:commands]).map { |c| [c[:verb], c[:creates]] } +
         Array(aggregate[:entity_commands]).map { |c| [c[:verb], false] }).map do |verb, creates|
          "        #{verb.inspect} => #{creates},"
        end
      end

      Exemplar.render("creates_table", '"tmpl_verb" => true,' => arms.join("\n"))
    end

    # Single-component identity only; a composite identity (more than one
    # component) is a known gap, skipped rather than guessed at.
    def emit_identity_head_table(aggregates)
      arms = aggregates.filter_map do |aggregate|
        heads = Array(aggregate[:identified_by])
        next if heads.size != 1

        head = heads.first.to_s.split(".").first
        qualified = "#{aggregate[:domain_name]}::#{aggregate[:name]}"
        "        #{qualified.inspect} => Some(#{head.inspect}),"
      end

      Exemplar.render("identity_head_table", '"tmpl_qualified" => Some("tmpl_head"),' => arms.join("\n"))
    end

    # Entity-level counterpart to emit_identity_head_table, keyed by
    # "Domain::Aggregate.Entity"; composite identities are out of scope.
    def emit_entity_identity_head_table(aggregates)
      arms = aggregates.flat_map do |aggregate|
        Array(aggregate[:entities]).filter_map do |entity|
          heads = Array(entity[:identified_by])
          next if heads.size != 1

          head = heads.first.to_s.split(".").first
          qualified = "#{aggregate[:domain_name]}::#{aggregate[:name]}.#{entity[:name]}"
          "        #{qualified.inspect} => Some(#{head.inspect}),"
        end
      end

      Exemplar.render("entity_identity_head_table", '"tmpl_qualified" => Some("tmpl_head"),' => arms.join("\n"))
    end

    # Declared attribute names per verb, used to filter a policy/process-
    # manager dispatch's with: facts down to what the target command declares.
    def emit_command_attributes_table(aggregates)
      arms = aggregates.flat_map do |aggregate|
        (Array(aggregate[:commands]) + Array(aggregate[:entity_commands])).map do |c|
          names = Array(c[:attributes]).map { |name| name.to_s.inspect }.join(", ")
          "        #{c[:verb].inspect} => &[#{names}],"
        end
      end

      Exemplar.render("command_attributes_table", '"tmpl_verb" => &["tmpl_attr"],' => arms.join("\n"))
    end
  end
end
