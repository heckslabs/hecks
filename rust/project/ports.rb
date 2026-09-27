require_relative "skip_reason"

module RustProjection
  module Projector
    module_function

    # A port operation has no givens or mutations, so the only ungenerable shape left is an
    # attribute type with no resolved Rust type.
    def port_operation_skip_reason(operation, _owner_name, value_objects_by_name)
      unresolved = operation[:attributes].reject do |attr|
        next true if attr[:list] # a list attribute's element type is checked below
        next true if reference_type?(attr[:type])
        next true if SCALAR.key?(attr[:type])

        value_objects_by_name.key?(attr[:type])
      end
      return skip("port_attribute_type", "attribute type(s) #{unresolved.map { |a| a[:type] }.uniq.join(', ')} not generated yet " \
                                         "(a value object this aggregate's own attributes never resolved a Rust type for)") if unresolved.any?

      nil
    end

    # Emits the args struct and a pure dispatch function that builds the events the operation
    # `emits`, addressed by `receiver_id`. Payloads are `Json::Null` placeholders; the registry's
    # `stamp_payload` replaces them. A self-reference to the owner is left out of the args.
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
          "id: receiver_id.to_string(), payload: crate::kernel::Json::Null, occurred_at: None, correlation: None },"
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
        emit_from_json_flat(args_struct, fact_attrs, value_objects_by_name, command_name: "#{port_name}.#{operation[:name]}",
                            interleave_checks: true, aggregates_by_name: aggregates_by_name),
        dispatch_fn,
      ].join("\n\n")
    end
  end
end
