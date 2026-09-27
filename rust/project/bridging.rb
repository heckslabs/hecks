module RustProjection
  module Projector
    module_function

    # `use` statements for value-object types this aggregate's commands
    # reference by name but don't declare locally (same chapter only).
    def cross_aggregate_vo_imports(aggregate, domain_value_object_owner, mod_name)
      local_names = aggregate[:value_objects].map { |vo| vo[:name] }.to_set
      attrs = (aggregate[:commands] + aggregate[:entities].flat_map { |e| e[:commands] } +
               aggregate[:ports].flat_map { |p| p[:operations] })
              .flat_map { |c| c[:attributes] }

      # A locally-declared type is never "foreign", even if some other
      # aggregate owns a VO of the same name domain-wide.
      foreign_types = attrs.map { |a| a[:type] }.uniq.reject { |type| local_names.include?(type) }
      foreign_types.filter_map { |type| domain_value_object_owner[type] && [type, domain_value_object_owner[type]] }
                   .sort_by { |(type, owner)| [owner, type] }
                   .map { |(type, owner)| "use crate::generated::#{mod_name}::#{owner.downcase}::#{rust_ident(type)};" }
    end

    # Whether target_vo's fields can all be filled from source_vo's fields
    # (matched by name) or the target's own defaults.
    def vo_field_bridgeable?(source_vo, target_vo)
      return false unless source_vo && target_vo
      return closed_sets_bridgeable?(source_vo, target_vo) if source_vo[:closed_set] || target_vo[:closed_set]

      target_vo[:attributes].all? do |t_attr|
        source_vo[:attributes].any? { |s_attr| s_attr[:name] == t_attr[:name] } || !t_attr[:default].nil?
      end
    end

    # Source closed-set members mappable to target members, or nil unless
    # every source member is also a target member (so the bridge can't fail).
    def closed_set_bridge_members(source_vo, target_vo)
      return nil unless source_vo[:closed_set] && target_vo[:closed_set]
      return nil unless source_vo[:attributes].size == 1 && target_vo[:attributes].size == 1

      target_values = target_vo[:members].map { |row| row.to_h.values.first.to_s }
      source_rows   = source_vo[:members]
      return nil unless source_rows.all? { |row| target_values.include?(row.to_h.values.first.to_s) }

      source_rows
    end

    def closed_sets_bridgeable?(source_vo, target_vo)
      !closed_set_bridge_members(source_vo, target_vo).nil?
    end

    def vo_field_rhs(source_expr, source_vo, target_type, value_objects_by_name)
      target_vo = value_objects_by_name[target_type]
      if (rows = closed_set_bridge_members(source_vo, target_vo))
        arms = rows.map { |row| "#{rust_ident(source_vo[:name])}::#{closed_set_variant(row)} => #{rust_ident(target_type)}::#{closed_set_variant(row)}" }
        return "match &#{source_expr} { #{arms.join(', ')} }"
      end

      fields = target_vo[:attributes].map do |t_attr|
        field = rust_ident_field(t_attr[:name])
        if source_vo[:attributes].any? { |s_attr| s_attr[:name] == t_attr[:name] }
          "#{field}: #{source_expr}.#{field}.clone()"
        else
          "#{field}: #{literal_rhs(t_attr[:default])}"
        end
      end
      "#{rust_ident(target_type)} { #{fields.join(', ')} }"
    end

    # Whether a value can move from source_type to target_type. Shared
    # with `value_rhs`, which performs the bridge this checks for.
    def bridgeable_value_types?(source_type, target_type, value_objects_by_name)
      return true if source_type == target_type
      # Compares Rust representations, not declared type names: a
      # `Reference<T>` and a bare `String` are both just `String`.
      return true if effective_scalar_type(source_type) && effective_scalar_type(source_type) == effective_scalar_type(target_type)

      source_vo = value_objects_by_name[source_type]
      target_vo = value_objects_by_name[target_type]
      return vo_field_bridgeable?(source_vo, target_vo) if target_vo

      # A single-field source VO unwraps into a bare scalar target when
      # that one field's own Rust representation already matches it.
      return false unless source_vo && !source_vo[:closed_set] && source_vo[:attributes].size == 1

      unwrapped_type = source_vo[:attributes].first[:type]
      unwrapped_type == target_type ||
        (effective_scalar_type(unwrapped_type) && effective_scalar_type(unwrapped_type) == effective_scalar_type(target_type))
    end

    def value_rhs(source_expr, source_type, target_type, value_objects_by_name)
      return "#{source_expr}.clone()" if source_type == target_type
      return "#{source_expr}.clone()" if effective_scalar_type(source_type) && effective_scalar_type(source_type) == effective_scalar_type(target_type)

      source_vo = value_objects_by_name[source_type]
      target_vo = value_objects_by_name[target_type]
      return vo_field_rhs(source_expr, source_vo, target_type, value_objects_by_name) if target_vo

      raise "unsupported coercion #{source_type} -> #{target_type} — bridgeable_value_types? should have caught this" unless source_vo && !source_vo[:closed_set] && source_vo[:attributes].size == 1

      "#{source_expr}.#{rust_ident_field(source_vo[:attributes].first[:name])}.clone()"
    end

    # Whether a list `:set` needs per-element rebuilding, rather than one
    # `.clone()`, because source and target elements differ in representation.
    def list_bridge_requires_element_mapping?(source_type, target_type)
      return false if source_type == target_type

      !(effective_scalar_type(source_type) && effective_scalar_type(source_type) == effective_scalar_type(target_type))
    end

    # `value_rhs`, mapped over each element of a list `:set` whose source
    # and target element types differ.
    def list_value_rhs(source_expr, source_type, target_type, value_objects_by_name)
      "#{source_expr}.iter().map(|item| #{value_rhs('item', source_type, target_type, value_objects_by_name)}).collect()"
    end

    def literal_set_bridgeable?(value, target_type, value_objects_by_name)
      return literal_hash_bridgeable?(value, target_type, value_objects_by_name) if value.is_a?(Hash) && target_type
      return false if value.is_a?(Hash)
      return false unless value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      return true unless target_type && value_objects_by_name[target_type]

      # A scalar literal into a single-field VO stands for that field's
      # value (mirrors `Value.for_attribute`'s runtime rewrap).
      sole = sole_field_of(target_type, value_objects_by_name)
      return false unless sole

      literal_hash_bridgeable?({ sole => value }, target_type, value_objects_by_name)
    end

    # The right-hand side for a literal into target_type: a Hash, a
    # scalar rewrapped into a single-field VO, or the scalar itself.
    def literal_rhs_for(value, target_type, value_objects_by_name)
      return literal_hash_rhs(value, target_type, value_objects_by_name) if value.is_a?(Hash)

      sole = target_type && value_objects_by_name[target_type] && sole_field_of(target_type, value_objects_by_name)
      return literal_hash_rhs({ sole => value }, target_type, value_objects_by_name) if sole

      literal_rhs(value)
    end

    # Whether a literal Hash supplies every field a target VO (or one
    # of its closed-set members) needs.
    def literal_hash_bridgeable?(hash, target_type, value_objects_by_name)
      vo = value_objects_by_name[target_type]
      return false unless vo

      if vo[:closed_set]
        vo[:members].any? { |member| member.all? { |field, value| [hash[field.to_sym], hash[field.to_s]].include?(value) } }
      else
        vo[:attributes].all? { |attr| hash.key?(attr[:name].to_sym) || hash.key?(attr[:name].to_s) }
      end
    end

    def literal_hash_rhs(hash, target_type, value_objects_by_name)
      vo = value_objects_by_name[target_type]
      raise "unsupported literal hash source #{hash.inspect} -> #{target_type} — literal_hash_bridgeable? should have caught this" unless vo

      if vo[:closed_set]
        row = vo[:members].find { |member| member.all? { |field, value| [hash[field.to_sym], hash[field.to_s]].include?(value) } }
        raise "literal #{hash.inspect} matches no member of #{target_type} — literal_hash_bridgeable? should have caught this" unless row

        "#{rust_ident(target_type)}::#{closed_set_variant(row)}"
      else
        fields = vo[:attributes].map do |attr|
          key = [attr[:name].to_sym, attr[:name].to_s].find { |k| hash.key?(k) }
          raise "literal #{hash.inspect} missing field #{attr[:name]} for #{target_type} — literal_hash_bridgeable? should have caught this" unless key

          "#{rust_ident_field(attr[:name])}: #{literal_rhs(hash[key])}"
        end
        "#{rust_ident(target_type)} { #{fields.join(', ')} }"
      end
    end

    def integer_field_of(vo)
      return nil unless vo && !vo[:closed_set]

      attr = vo[:attributes].find { |a| a[:type] == "Integer" }
      attr && attr[:name]
    end

    # The attribute and its one Integer field an `:increment`/`:decrement`
    # touches, or nil unless the target is a single-field integer VO.
    def arithmetic_target_field(mutation, aggregate, value_objects_by_name)
      target_attr = aggregate[:attributes].find { |a| a[:name].to_s == mutation[:target].to_s }
      return nil unless target_attr && !target_attr[:list]

      field = integer_field_of(value_objects_by_name[target_attr[:type]])
      field && [target_attr, field]
    end

    # The amount side of an `:increment`/`:decrement` as a raw Rust
    # integer expression. Returns nil, not raise, when nothing bridges.
    def arithmetic_amount_expr(source, command, value_objects_by_name, target_integer_field)
      if source[:kind] == "literal"
        value = source[:value]
        return literal_rhs(value) if value.is_a?(Integer)
        return nil unless value.is_a?(Hash)

        key = [target_integer_field.to_sym, target_integer_field.to_s].find { |k| value.key?(k) }
        key && value[key].is_a?(Integer) ? literal_rhs(value[key]) : nil
      elsif source[:kind] == "argument"
        arg_attr = command[:attributes].find { |a| a[:name].to_s == source[:name] }
        return nil unless arg_attr
        return "args.#{rust_ident_field(arg_attr[:name])}" if arg_attr[:type] == "Integer"

        field = integer_field_of(value_objects_by_name[arg_attr[:type]])
        field && "args.#{rust_ident_field(arg_attr[:name])}.#{rust_ident_field(field)}"
      end
    end

    # `clamp:`'s literal `[min, max]` bounds, or nil for anything else
    # (non-literal source, wrong length, non-Integer bound).
    def clamp_bounds_ints(source)
      return nil unless source[:kind] == "literal"

      value = source[:value]
      return nil unless value.is_a?(Array) && value.size == 2 && value.all? { |v| v.is_a?(Integer) }

      value
    end

    # The default for an attribute a creating command's arguments don't
    # mention: its own default, or one built from its VO's field defaults.
    def creation_default_rhs(attr, value_objects_by_name)
      default = attr[:default]
      unless default.nil?
        return literal_rhs(default) unless default.is_a?(Hash)

        # Completes a partial Hash default with the target VO's own
        # per-field defaults first; `literal_hash_rhs` requires every
        # field present.
        return literal_hash_rhs(complete_hash_default(default, attr[:type], value_objects_by_name), attr[:type], value_objects_by_name)
      end

      vo = value_objects_by_name[attr[:type]]
      return nil unless vo && !vo[:closed_set] && vo[:attributes].all? { |f| !f[:default].nil? }

      fields = vo[:attributes].map { |f| "#{rust_ident_field(f[:name])}: #{literal_rhs(f[:default])}" }
      "#{rust_ident(attr[:type])} { #{fields.join(', ')} }"
    end

    # Fields present in `hash`, plus any the target VO defaults on its
    # own; a field with neither is left out, not set to nil.
    def complete_hash_default(hash, target_type, value_objects_by_name)
      vo = value_objects_by_name[target_type]
      return hash unless vo && !vo[:closed_set]

      vo[:attributes].each_with_object({}) do |field, completed|
        key = [field[:name].to_sym, field[:name].to_s].find { |k| hash.key?(k) }
        if key
          completed[field[:name].to_sym] = hash[key]
        elsif !field[:default].nil?
          completed[field[:name].to_sym] = field[:default]
        end
      end
    end
  end
end
