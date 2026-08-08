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
    # CROSS-DOMAIN POLICIES ARE SKIPPED, loudly, not silently narrowed:
    # `bin/project_rust <domain>` compiles exactly ONE target domain (plus
    # the self-hosted meta-language) into one `Store` — a policy whose
    # `across` names a domain THIS build never generated has no
    # `dispatch_by_name`/`Store` to route to at all, structurally, the same
    # way Ruby's own `PolicyInterpreter#deliver` refuses one reaching a
    # domain that was never loaded ("no domain \"X\" loaded" —
    # policy_interpreter.rb, read directly) UNLESS that domain's bluebook
    # sits alongside the target's in the same directory and gets loaded by
    # the SAME boot. Checked live against this corpus: `examples/banking/
    # bluebook/` holds only `banking.bluebook` — no `Compliance`/
    # `Notifications` bluebook exists anywhere in this repo — so Ruby's OWN
    # runtime already refuses these identically (a no-op on final state
    # either way). A future domain that DOES co-locate its cross-domain
    # policy targets would need `bin/project_rust` to compile more than one
    # domain into one `Store` before this could route them — a real,
    # separate, still-open gap, not attempted here.
    def emit_policy_table(domain_name, policies)
      rows = policies.filter_map do |policy|
        target_domain = policy[:target_domain] || domain_name
        next nil unless target_domain == domain_name

        event_name = policy_event_name(policy[:on_event])
        qualifier = policy_event_qualifier(policy[:on_event])
        qualifier_expr = qualifier ? "Some(#{qualifier.inspect})" : "None"
        target_verb = "#{target_domain}::#{policy[:trigger_command]}"

        "    crate::kernel::PolicyRule { event_name: #{event_name.inspect}, event_qualifier: #{qualifier_expr}, target_verb: #{target_verb.inspect} },"
      end

      skipped = policies.size - rows.size
      puts "policy table: #{rows.size} routable, #{skipped} cross-domain (skipped — see reactions.rb's own header)" if skipped.positive?

      <<~RUST
        pub const POLICIES: &[crate::kernel::PolicyRule] = &[
        #{rows.join("\n")}
        ];
      RUST
    end

    # A `with:` binding's raw wire spelling — `IR.render_value`'s own two
    # shapes (lib/hecksagain/query_specification/common/comparators.rb,
    # read directly): a Symbol becomes ":name"; anything else becomes
    # `.to_s` (a Hash's own `.inspect` form — Ruby's `Hash#to_s` IS
    # `#inspect`). `Marks.read` is the exact, already-proven inverse
    # (bridging.rb's `literal_hash_rhs` callers use `Marks.unmark` for the
    # identical round trip on a `then_set append:` literal field) — reused
    # rather than re-derived.
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
      literal_fns << "fn #{fn_name}() -> crate::kernel::Json { #{json_literal_expr(parsed)} }"
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

      <<~RUST
        #{literal_fns.join("\n")}

        pub const PROCESS_MANAGERS: &[crate::kernel::ProcessManagerDef] = &[
        #{pm_exprs.map { |e| "    #{e}," }.join("\n")}
        ];
      RUST
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
    def emit_reference_key_table(domain_name, aggregate_names)
      arms = aggregate_names.map do |name|
        qualified = "#{domain_name}::#{name}"
        key = Hecksagain::Naming.snake(name)
        "        #{qualified.inspect} => Some(#{key.inspect}),"
      end

      <<~RUST
        pub fn reference_key_for_aggregate(qualified_name: &str) -> Option<&'static str> {
            match qualified_name {
        #{arms.join("\n")}
                _ => None,
            }
        }
      RUST
    end
  end
end
