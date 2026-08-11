module RustProjection
  module Projector
    module_function

    # `IR::Policy#event_qualifier`/`#event_name` (`Naming.qualifier`/
    # `Naming.unqualified`, read directly) — NOT separate wire fields
    # (`IR::Policy#to_h` only carries `on_event` whole); the exported
    # canonical IR gives this generator the same raw `on_event` string
    # Ruby's own runtime re-derives these from, so it re-derives them the
    # identical way rather than exporting a fourth field the wire contract
    # doesn't have.
    def policy_event_qualifier(on_event)
      text = on_event.to_s
      text.include?(".") ? text.split(".", 2).first : nil
    end

    def policy_event_name(on_event)
      text = on_event.to_s
      text.include?(".") ? text.split(".", 2).last : text
    end

    # ── THE POLICY TABLE — `kernel::orchestrate`'s own static data,
    # `Runtime::PolicyInterpreter#policies_for`/`#deliver` ported to
    # generated `PolicyRule` rows a hand-written, generic function walks
    # (kernel/orchestrate.rs), the SAME "compile shapes, interpret
    # behavior" split every other generated/kernel pair in this project
    # already holds to.
    #
    # CROSS-DOMAIN POLICIES ARE SPLIT OUT, not skipped: `bin/project_rust
    # <domain>` still compiles exactly ONE target domain (plus the
    # self-hosted meta-language) into one `Store` — a policy whose
    # `across` names a domain THIS build never generated still has no
    # `dispatch_by_name`/`Store` to route to LOCALLY. What changed is
    # that local dispatch is no longer the only way this project delivers
    # a command: `rust/host` (the unsandboxed host layer, real AWS SDK
    # access this WASM-compiled kernel structurally lacks — see
    # orchestrate.rs's own header) can invoke that OTHER domain's own
    # deployed Lambda directly, a straight port of Ruby's own
    # `Adapters::Lambda::Client`. `emit_cross_domain_policy_table`, below,
    # emits these rows into their OWN table (`CrossDomainPolicyRule`, not
    # `PolicyRule` — a different shape, since there is no local
    # `target_verb` to dispatch, only a domain+verb pair for rust/host's
    # `lambda_client.rs` to invoke remotely) instead of dropping them.
    def emit_policy_table(domain_name, policies)
      rows = local_policy_rows(domain_name, policies)

      Exemplar.render(
        "policy_table",
        'crate::kernel::PolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_verb: "tmpl_target_verb" },' => rows.join("\n")
      )
    end

    def local_policy_rows(domain_name, policies)
      policies.filter_map do |policy|
        target_domain = policy[:target_domain] || domain_name
        next nil unless target_domain == domain_name

        event_name = policy_event_name(policy[:on_event])
        qualifier = policy_event_qualifier(policy[:on_event])
        qualifier_expr = qualifier ? "Some(#{qualifier.inspect})" : "None"
        target_verb = "#{target_domain}::#{policy[:trigger_command]}"

        # `policy_name` — orchestrate.rs's own `reaction_log`/`saga_log`
        # entries need the policy's own declared name (`PolicyInterpreter
        # #deliver`'s `record = { policy: policy.name, ... }`, read
        # directly) — previously absent here on purpose (this struct's own
        # OLD header: "nothing downstream of a same-domain reaction ever
        # needed to name the policy that caused it"), now needed the same
        # way `CrossDomainPolicyRule` already carries it.
        "    crate::kernel::PolicyRule { policy_name: #{policy[:name].to_s.inspect}, event_name: #{event_name.inspect}, " \
          "event_qualifier: #{qualifier_expr}, target_verb: #{target_verb.inspect} },"
      end
    end

    # ── THE CROSS-DOMAIN POLICY TABLE — every policy `local_policy_rows`
    # above filtered OUT, represented instead of dropped. `target_verb`
    # here is FULLY QUALIFIED (`"#{target_domain}::#{trigger_command}"`),
    # the SAME formula `local_policy_rows` uses, above — NOT the bare
    # `policy[:trigger_command]` this used to emit.
    #
    # FOUND LIVE, deploying a real second domain (Compliance) to actually
    # prove cross-domain delivery for the first time: a bare verb refuses
    # with "unknown command" against ANY compiled target, single-chapter
    # or not — `dispatch_by_name`'s own generated match arms are ALWAYS
    # "Domain::Aggregate.Command", the same convention every other verb
    # in this whole system already uses (`kernel::cli::run`'s own
    # top-level step, `RemoteDispatcher#dispatch`'s real cross-Lambda
    # calls, `Adapters::Lambda::Client#dispatch`). The OLD reasoning here
    # ("the Lambda invoked IS the domain, so the verb it receives is
    # already implicitly scoped to it") assumed a target Lambda's own
    # dispatch table could somehow be UNqualified for a single-chapter
    # compile — never actually true; nothing in `rust/project/registry.rb`
    # ever emits an unqualified match arm. Confirmed both ways: compiled
    # `examples/compliance` refuses a bare "AccountFreezeReview.Open" as
    # "unknown command" and accepts "Compliance::AccountFreezeReview.Open"
    # cleanly. This was never caught before because no domain had ever
    # deployed a real second Lambda to receive one of these calls.
    def emit_cross_domain_policy_table(domain_name, policies)
      rows = policies.filter_map do |policy|
        target_domain = policy[:target_domain] || domain_name
        next nil if target_domain == domain_name

        event_name = policy_event_name(policy[:on_event])
        qualifier = policy_event_qualifier(policy[:on_event])
        qualifier_expr = qualifier ? "Some(#{qualifier.inspect})" : "None"
        target_verb = "#{target_domain}::#{policy[:trigger_command]}"

        "    crate::kernel::CrossDomainPolicyRule { policy_name: #{policy[:name].to_s.inspect}, event_name: #{event_name.inspect}, " \
          "event_qualifier: #{qualifier_expr}, target_domain: #{target_domain.inspect}, target_verb: #{target_verb.inspect} },"
      end

      puts "cross-domain policy table: #{rows.size} row(s) — delivered by rust/host's lambda_client.rs, not locally dispatched" if rows.any?

      Exemplar.render(
        "cross_domain_policy_table",
        'crate::kernel::CrossDomainPolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_domain: "tmpl_target_domain", target_verb: "tmpl_target_verb" },' =>
          rows.join("\n")
      )
    end

    # A `with:` binding's raw wire spelling — Hecksagain::Literal's, the
    # same one every other to_h-bound literal field rides. `Marks.read` is
    # the exact, already-proven inverse (mutations.rb's
    # `append_field_source` is the identical round trip on a `then_set
    # append:` field) — reused rather than re-derived.
    def with_value_parsed(raw)
      Hecksagain::Bluebook::Assembly::Marks.read(raw)
    end

    # A parsed `with:` literal (`Marks.read`'s own output shape for
    # anything that isn't a Symbol — a Hash/String/Integer/Float/Boolean/
    # nil) to a Rust expression BUILDING the equivalent `Json` value —
    # never a `const` literal (`Json` holds `Vec`/`String`, not
    # `const`-constructible in stable Rust), which is why every literal
    # gets its own one-off generated function (`emit_with_value`, below).
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

    # One `with:` binding, resolved to a `WithValue` — a bare Symbol is a
    # RUNTIME reference (`WithValue::Ref`, resolved by
    # `kernel::orchestrate`'s `resolve_with`); anything else is a LITERAL,
    # emitted as its own tiny `fn() -> Json` (`literal_fns` collects these
    # so the caller can splice them in above the table that references
    # them by name).
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

    def emit_dispatch_spec(spec, literal_fns)
      with_pairs = spec[:with_spec].map { |key, raw| "(#{key.to_s.inspect}, #{emit_with_value(raw, literal_fns)})" }
      "crate::kernel::DispatchSpec { command_name: #{spec[:command_name].inspect}, with: &[#{with_pairs.join(', ')}] }"
    end

    def emit_handler(handler, literal_fns)
      dispatches = handler[:dispatches].map { |d| emit_dispatch_spec(d, literal_fns) }
      "crate::kernel::Handler { event_type: #{handler[:event_type].inspect}, from_state: #{handler[:from_state].inspect}, to_state: #{handler[:to_state].inspect}, dispatches: &[#{dispatches.join(', ')}] }"
    end

    # ── THE PROCESS MANAGER TABLE — `kernel::orchestrate`'s own static
    # data for `SagaInterpreter#advance`/`#unwind`, the same "compile
    # shapes, interpret behavior" split the policy table above holds to.
    # No cross-domain narrowing needed here the way `emit_policy_table`
    # needs one: every `dispatch` spec's `command_name` is ALREADY fully
    # domain-qualified on the wire (`Banking::Account.Debit`, not
    # `Account.Debit`) — a process manager cannot name a target this
    # single-domain `Store` doesn't hold without that verb simply failing
    # to route at `dispatch_by_name`'s own `unknown command` branch, the
    # same swallowed-refusal path any other unreachable target takes.
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

    # `Naming.reference_key(event.aggregate)`, precomputed per aggregate
    # rather than re-derived at runtime — `Correlation#saga_correlation`'s
    # own THIRD tier (this file's own header on `orchestrate.rs`), needed
    # for real: a leg dispatched WITH its own `reference_to` argument
    # (`Transfer.Credited`'s own `transfer:`, `json_codec.rb`'s
    # `emit_extract_id` header) announces an event whose payload carries
    # THAT key, not `correlates_by`'s own dotted field — `TransferCredited`
    # only ever has `{"transfer": "xfer-1"}`, never `{"reference": {...}}`.
    # `kernel::orchestrate`'s `correlation_of` falls back to this table,
    # keyed by the emitting event's OWN qualified aggregate name, exactly
    # the same per-event (not per-process-manager) rule Ruby's own
    # `Naming.reference_key(event.aggregate)` applies.
    # `chapters` — `[[domain_name, aggregate_names], ...]`, one pair per
    # chapter (bin/project_rust's own per-domain call for a single-
    # chapter registry.rs passes exactly one pair; the merged registry
    # spanning every chapter a domain attaches passes one pair per
    # chapter) — this table is domain-qualified-name -> key regardless
    # of how many chapters fed it, so merging is just "more pairs in
    # the same flat list," no other change needed.
    def emit_reference_key_table(chapters)
      arms = chapters.flat_map do |domain_name, aggregate_names|
        aggregate_names.map do |name|
          qualified = "#{domain_name}::#{name}"
          key = Hecksagain::Naming.snake(name)
          "        #{qualified.inspect} => Some(#{key.inspect}),"
        end
      end

      Exemplar.render("reference_key_table", '"tmpl_qualified" => Some("tmpl_key"),' => arms.join("\n"))
    end
  end
end
