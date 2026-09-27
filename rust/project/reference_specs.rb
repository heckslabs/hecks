module RustProjection
  module Projector
    module_function

    # Per-attribute reference specs for one declaring node, computed at codegen time.
    # Mirrors the walk in `CommandRules::References#dereference`.
    def reference_specs(domain_name, attributes)
      attributes.filter_map do |attr|
        target = reference_target(attr[:type])
        next unless target

        { field: attr[:name].to_s, as_name: attr[:name].to_s.sub(/_id\z/, ""), target: "#{domain_name}::#{target}" }
      end
    end

    def emit_reference_spec(spec)
      "crate::kernel::ReferenceSpec { field: #{spec[:field].inspect}, as_name: #{spec[:as_name].inspect}, target: #{spec[:target].inspect} }"
    end

    # `&[]` when empty: call sites need a `&'static [ReferenceSpec]` expression.
    def emit_reference_specs_literal(specs)
      return "&[]" if specs.empty?

      "&[#{specs.map { |s| emit_reference_spec(s) }.join(', ')}]"
    end
  end
end
