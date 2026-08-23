module RustProjection
  module Projector
    module_function

    # `PortOperation` has no `references`/`givens`/`mutations`/`ensures`
    # at all (its own header: "a port is the anti-corruption boundary that
    # turns an external call into a fact... not a second place business
    # rules live") — so `command_skip_reason`'s own long list of ungenerable
    # SHAPES mostly does not apply here; the two real ones that still can:
    # a list attribute carrying `admits:`/`pattern:` (the exact same
    # per-element gap `constraint_list_problems` already names for
    # commands), and an attribute type this domain's own aggregate-level
    # check never resolved a Rust type for (a port introducing a value
    # object no OTHER attribute anywhere in this aggregate already forced
    # into existence — no real operation in this corpus does that; flagged
    # rather than silently assumed impossible).
    #
    # NO LONGER REQUIRES A `reference_to <owner>` ATTRIBUTE — routing
    # separation (`to:`/`with:`) supplies the receiver identity externally
    # now, the same way an acting COMMAND's own identity does
    # (`registry.rb`'s `CommandInvocation#split_aggregate_receiver`), so a
    # self-reference on the operation is a migration-era spelling of its
    # receiver at most, never a requirement. `Pizzas::Order.PaymentGateway.
    # Receive` — the corpus's one live port operation — declares no such
    # reference at all and used to be skipped here as a codegen bug; it
    # generates for real now.
    def port_operation_skip_reason(operation, _owner_name, value_objects_by_name)
      constraint_problems = constraint_list_problems(operation)
      return constraint_problems.join('; ') if constraint_problems.any?

      unresolved = operation[:attributes].reject do |attr|
        next true if attr[:list] # a list attribute's element type is checked below, same as constraint_list_problems
        next true if reference_type?(attr[:type])
        next true if SCALAR.key?(attr[:type])

        value_objects_by_name.key?(attr[:type])
      end
      return "attribute type(s) #{unresolved.map { |a| a[:type] }.uniq.join(', ')} not generated yet " \
             "(a value object this aggregate's own attributes never resolved a Rust type for)" if unresolved.any?

      nil
    end

    # ── ONE emitter per port operation — the args struct plus a pure
    # dispatch function with no repo, no Hydrate, no mutation record: an
    # operation neither hydrates nor saves an aggregate instance
    # (`PortOperationInterpreter#call`'s own shorter `DISPATCH_ORDER`,
    # ported the same way `emit_entity_command` ports `EntityInterpreter
    # #call`'s). `registry.rb`'s own `emit_reference_check` runs BEFORE
    # this function is even called (the same "needs `store`, only exists
    # at the router level" reason a command's own reference checks do,
    # `reactions.rb`'s header) — by the time control reaches here, the
    # referenced aggregate is already known to exist, so this only builds
    # the event(s) the operation's own `emits` names, addressed by
    # `receiver_id` — the router's own resolved receiver identity
    # (`CommandInvocation#split_aggregate_receiver`, registry.rb), passed
    # in as this function's own first parameter now rather than read off a
    # declared attribute. The payload this function's own events carry is
    # a placeholder (`Json::Null`) — `registry.rb`'s generated call site
    # wraps the return with the SAME `stamp_payload(events, &payload)` a
    # command's own dispatch call already does, which REPLACES it with the
    # router's real, raw facts — so this function never needs to build a
    # correct payload itself, only correct `name`/`aggregate`/`id`.
    #
    # A SELF-REFERENCE ATTRIBUTE (`reference_to <owner>`, the migration-era
    # spelling of this same receiver) is EXCLUDED from the generated args
    # struct/JSON codec/event payload entirely — it names no external fact
    # once routing supplies the receiver, the same reason `registry.rb`'s
    # `emit_registry` strips it from `facts_json` via `split_aggregate_
    # receiver`'s own `legacy_receiver_field` when one is present.
    def emit_port_operation(operation, port_name, owner_name, domain_name, value_objects_by_name, aggregates_by_name)
      args_struct = "#{rust_ident(port_name)}#{rust_ident(operation[:name])}Args"
      qualified   = "#{domain_name}::#{owner_name}"
      fact_attrs  = operation[:attributes].reject { |attr| reference_target(attr[:type]) == owner_name }

      struct_lines = ["pub struct #{args_struct} {"]
      fact_attrs.each do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        type = "Option<#{type}>" if attr[:optional]
        struct_lines << "    #{Exemplar.render('struct_field', 'TmplFieldType' => type, 'tmpl_field' => rust_ident_field(attr[:name]))}"
      end
      struct_lines << "}"

      invariant_checks = invariant_checks_for(operation, aggregates_by_name, value_objects_by_name)
      fn = "#{port_name.downcase}_#{dispatch_fn_name(rust_ident(operation[:name]))}"

      events = operation[:emits].map do |event_name|
        "        crate::kernel::Event { name: #{event_name.inspect}.to_string(), aggregate: #{qualified.inspect}.to_string(), " \
          "id: receiver_id.to_string(), payload: crate::kernel::Json::Null, correlation: None },"
      end

      dispatch_fn = <<~RUST.rstrip
        pub fn dispatch_operation_#{fn}(receiver_id: &str, args: #{args_struct}) -> Result<Vec<crate::kernel::Event>, crate::kernel::Refusal> {
        #{invariant_checks.join("\n")}
            Ok(vec![
        #{events.join("\n")}
            ])
        }
      RUST

      [
        "#[derive(Debug, Clone)]\n#{struct_lines.join("\n")}",
        emit_to_json_flat(args_struct, fact_attrs, value_objects_by_name),
        emit_from_json_flat(args_struct, fact_attrs, value_objects_by_name, command_name: "#{port_name}.#{operation[:name]}"),
        dispatch_fn,
      ].join("\n\n")
    end
  end
end
