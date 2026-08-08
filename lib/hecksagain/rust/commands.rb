module Hecksagain
  module Rust
    module Projector
      module_function

      def command_skip_reason(command, aggregate, value_objects_by_name)
        unsupported_ops = command[:mutations].reject { |m| %i[append set increment decrement].include?(m[:op]) }.map { |m| m[:op] }.uniq
        return "then_set op(s) #{unsupported_ops.join(', ')} not generated yet (only append/set/increment/decrement are)" if unsupported_ops.any?

        append_problems = append_field_problems(command, aggregate, value_objects_by_name)
        return "then_set append field(s): #{append_problems.join('; ')}" if append_problems.any?

        lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_sym
        target_type_for = ->(target) { target == lifecycle_field ? "String" : aggregate[:attributes].find { |a| a[:name] == target }&.dig(:type) }

        # A `:set` mutation's literal source is EITHER a bare scalar (`to:
        # "sold"`) or a raw Ruby Hash (`to: { value: "good" }` —
        # Command::Mutation#classified_source wraps any non-Symbol source as
        # `{kind: "literal", value: source}` UNTOUCHED, unlike `:append`'s
        # `.inspect`'d fields, so a literal value object needs no re-parsing —
        # `literal_hash_rhs`, above, builds its Rust struct literal straight
        # from the Hash). Bridgeable only when every field the target VO
        # declares is actually present in the literal; checked generically (not
        # just "is it a Hash") so nothing NEW and unexpected can crash the run
        # instead of being skipped.
        literal_set_targets = command[:mutations].select do |m|
          next false unless m[:op] == :set && m[:source][:kind] == "literal"

          !literal_set_bridgeable?(m[:source][:value], target_type_for.call(m[:target]), value_objects_by_name)
        end.map { |m| m[:target] }
        return "then_set to: a literal that doesn't bridge to the target's type (#{literal_set_targets.join(', ')}) — not generated yet" if literal_set_targets.any?

        # Ruby's real `apply`, for `:set`, does `Value.for(aggregate, mutation.target,
        # value)` — it coerces whatever arrived into the TARGET attribute's OWN
        # declared type, regardless of what type the SOURCE argument was declared
        # as (found live: the self-hosted grammar sets an `IdentityField`-typed
        # attribute from a `FieldName`-typed argument — different value objects,
        # same one-`value`-field shape). This generator's `:set` just clones the
        # argument's own type straight across, which only compiles when source
        # and target genuinely agree — checked here so a real mismatch is a named
        # skip, not a `cargo build` error with no Ruby-side explanation.
        mismatched_sets = command[:mutations].select do |m|
          next false unless m[:op] == :set && m[:source][:kind] == "argument"

          target_type = target_type_for.call(m[:target])
          source_type = command[:attributes].find { |a| a[:name].to_s == m[:source][:name] }&.dig(:type)
          target_type && source_type && !bridgeable_value_types?(source_type, target_type, value_objects_by_name)
        end.map { |m| m[:target] }
        return "then_set :#{mismatched_sets.join(', ')} sources an argument no single-field rewrap can bridge to the target's type — not generated yet" if mismatched_sets.any?

        # `:increment`/`:decrement` — Ruby's real `arithmetic_value_object`
        # (command_rules/arithmetic.rb, read directly) finds the ONE field
        # that's `Integer` in both the target VO and the (already
        # target-type-coerced) amount, and changes only that field. Bridgeable
        # when the target names such a field AND the amount resolves to a raw
        # integer expression — `arithmetic_amount_expr`, above, is the same
        # "can we generate this" / "here's how" pairing `bridgeable_value_types?`/
        # `value_rhs` already use for `:set`.
        arithmetic_targets = command[:mutations].select { |m| %i[increment decrement].include?(m[:op]) }
        unsupported_arithmetic = arithmetic_targets.reject do |m|
          target = arithmetic_target_field(m, aggregate, value_objects_by_name)
          target && arithmetic_amount_expr(m[:source], command, value_objects_by_name, target[1])
        end.map { |m| m[:target] }
        return "then_set :#{unsupported_arithmetic.join(', ')} increment/decrement amount or target field isn't bridgeable — not generated yet" if unsupported_arithmetic.any?

        nil
      end

      # ── ONE emitter for every command shape kernel::dispatch can run —
      # creating or acting, with or without givens or an append mutation.
      # What used to be emit_create_command's implicit, name-matched
      # `assign_creation_attributes` step now lives inside the `Hydrate::Create`
      # `build` closure; what used to be emit_act_command's given/mutation
      # generation is now just data (`GivenSpec`s, a closure) handed to
      # kernel::dispatch instead of hand-assembled control flow.
      def emit_command(command, aggregate, domain_name, value_objects_by_name)
        record = rust_ident(aggregate[:name])
        cmd    = rust_ident(command[:name])
        creates = command[:references].nil?
        identity = identity_components(aggregate, command)
        identity_extra_params = identity.filter_map { |c| c[:param] }

        args_struct = ["pub struct #{cmd}Args {"]
        command[:attributes].each do |attr|
          type = rust_type(attr[:type], list: attr[:list])
          args_struct << "    pub #{rust_ident_field(attr[:name])}: #{type},"
        end
        args_struct << "}"

        invariant_checks = command[:attributes].filter_map do |attr|
          next unless value_objects_by_name.key?(attr[:type])
          next if value_objects_by_name[attr[:type]][:closed_set]

          field = rust_ident_field(attr[:name])
          attr[:list] ? "        for item in &args.#{field} { item.check_invariants()?; }" : "        args.#{field}.check_invariants()?;"
        end

        given_specs = command[:givens].map do |given|
          "            crate::kernel::GivenSpec { description: #{given[:description].inspect}, expr: #{ExprEmitter.emit_predicate(given[:canonical])} },"
        end

        ensures_specs = command[:ensures].map do |rule|
          "            crate::kernel::EnsuresSpec { description: #{rule[:description].inspect}, expr: #{ExprEmitter.emit_predicate(rule[:canonical])} },"
        end

        payload_lines = command[:attributes].map do |attr|
          vo = value_objects_by_name[attr[:type]]
          field = rust_ident_field(attr[:name])
          # A single-field CLOSED SET (`AccountKind`, `Size`) is a Rust ENUM,
          # not a struct — `emit_value_object`'s own branch on `closed_set`
          # — so it carries no named field to read here the way an ordinary
          # single-field VO does. `{:?}` on the enum value itself already
          # renders something readable.
          if vo && !vo[:closed_set] && !attr[:list] && vo[:attributes].size == 1
            inner = rust_ident_field(vo[:attributes].first[:name])
            %(payload.insert("#{attr[:name]}".to_string(), format!("{:?}", args.#{field}.#{inner})); )
          else
            %(payload.insert("#{attr[:name]}".to_string(), format!("{:?}", args.#{field})); )
          end
        end

        transition = lifecycle_transition_for(command, aggregate)
        transition_arg =
          if transition
            "Some(crate::kernel::TransitionCheck { field: #{transition[:field].inspect}, from_states: &[#{transition[:from_states].map(&:inspect).join(', ')}] })"
          else
            "None"
          end

        mutation_lines = command[:mutations].map { |m| emit_mutation_line(m, aggregate, command, value_objects_by_name) }
        # advance_lifecycle: unconditional once a transition applies at all —
        # see kernel/dispatch.rs's TransitionCheck comment for why this lives
        # here, as one more line in the SAME closure, rather than as its own
        # dispatch() step. Covers commands with no explicit then_set on the
        # lifecycle field (Banking's Freeze/Unfreeze have none) — Purchase's
        # own explicit then_set above already covers itself, redundantly.
        mutation_lines << "        record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition
        mutation_lines = ["        let _ = record;"] if mutation_lines.empty? # nothing to apply — silence the unused-param warning

        if creates
          record_fields = aggregate[:attributes].map do |attr|
            matched = command[:attributes].find { |a| a[:name] == attr[:name] }
            field = rust_ident_field(attr[:name])
            if matched
              attr[:list] ? "            #{field}: args.#{field}.clone()," : "            #{field}: Some(args.#{field}.clone()),"
            elsif attr[:list]
              "            #{field}: vec![],"
            else
              default_rhs = creation_default_rhs(attr, value_objects_by_name)
              default_rhs ? "            #{field}: Some(#{default_rhs})," : "            #{field}: None,"
            end
          end
          record_fields << "            #{rust_ident_field(aggregate[:lifecycle][:field])}: #{aggregate[:lifecycle][:default].inspect}.to_string()," if aggregate[:lifecycle]

          hydrate = <<~RUST.rstrip
            crate::kernel::Hydrate::Create {
                    id: #{build_identity_expr(identity)},
                    build: Box::new(|| #{record} {
            #{record_fields.join("\n")}
                    }),
                }
          RUST
          fn_signature = (["repo: &mut impl crate::kernel::Repository<#{record}>"] + identity_extra_params + ["args: #{cmd}Args"]).join(", ")
        else
          hydrate = %(crate::kernel::Hydrate::Act { id: id.to_string() })
          fn_signature = "repo: &mut impl crate::kernel::Repository<#{record}>, id: &str, args: #{cmd}Args"
        end

        <<~RUST
          #{emit_fielded_flat("#{cmd}Args", command[:attributes], value_objects_by_name)}

          #[derive(Debug, Clone)]
          #{args_struct.join("\n")}

          pub fn dispatch_#{dispatch_fn_name(cmd)}(
              #{fn_signature},
          ) -> crate::kernel::DispatchResult<#{record}> {
          #{invariant_checks.join("\n")}

              let mut payload = std::collections::BTreeMap::new();
              #{payload_lines.join("\n        ")}

              crate::kernel::dispatch(
                  repo,
                  #{hydrate},
                  #{cmd.inspect},
                  #{"#{domain_name}::#{aggregate[:name]}".inspect},
                  &args,
                  &[
          #{given_specs.join("\n")}
                  ],
                  #{transition_arg},
                  |record| {
          #{mutation_lines.join("\n")}
                      Ok(())
                  },
                  &[
          #{ensures_specs.join("\n")}
                  ],
                  &[#{command[:emits].map(&:inspect).join(", ")}],
                  payload,
              )
          }
        RUST
      end
    end
  end
end
