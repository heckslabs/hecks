module RustProjection
  module Projector
    module_function

    # `CommandRules::References#dereference`'s own per-attribute walk
    # (references.rb, read directly: `owner.attributes.each_with_object({})
    # { next unless attribute.reference?; ...; name = attribute.name.to_s.
    # sub(/_id\z/, "").to_sym }`), computed once here at codegen time
    # instead of per-dispatch. Reused for THREE distinct "declaring node"s
    # — an aggregate/entity's own attributes (an ACTING command's `owner_
    # deref`, registry.rb), a command's own attributes (`command_deref`,
    # covering BOTH a creating command's reference arguments and an acting
    # command's extra ones, e.g. `CardPayment.Dispute`'s `disputed_by`),
    # and every OTHER generated aggregate (the domain-wide `REFERENCE_TABLE`
    # `deref_layer`'s own runtime recursion looks up by name, so this
    # generator doesn't have to re-walk the whole reference graph per
    # command) — the identical shape either way, just aimed at whichever
    # `attributes` list the caller hands it.
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

    # `&[]` for the (common) empty case — NOT a bare `[]`: every call site
    # expects a real `&'static [crate::kernel::ReferenceSpec]` expression,
    # and `&[]` is exactly that (a zero-length slice literal, universally
    # `'static` with no promotion subtlety, the same way an EMPTY exemplar
    # array marker elsewhere in this generator renders `&[]` rather than
    # nothing at all).
    def emit_reference_specs_literal(specs)
      return "&[]" if specs.empty?

      "&[#{specs.map { |s| emit_reference_spec(s) }.join(', ')}]"
    end
  end
end
