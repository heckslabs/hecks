module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # Checks `with:` projections of policies and saga legs against the source event's shape
          # and the target command's fields.
          module WithProjections
            # What every `with:` check shares: the chapter's commands by "Owner.Command", its
            # aggregates, and the sagas' correlation heads.
            WithContext = Struct.new(:lookup, :aggregates, :correlation_heads)
            # One `with:` to check: the command it targets, the event it reads from, the spec
            # itself, how a refusal names it, and the process manager when it is a saga leg.
            WithSpec = Struct.new(:command_ref, :event_name, :with_spec, :label, :process_manager, :row_names)
            # What a `with:` source may read: the correlation key, the emitter's identity heads and
            # the event shapes whose fields are legal, and a fan-out row's names (empty off a
            # fan-out).
            Readable = Struct.new(:correlation, :identity, :shapes, :row)
            private_constant :WithContext, :WithSpec, :Readable

            private

            # Checks `with:` projections against the source event's shape and the target's fields.
            # Same-chapter only: an unresolvable cross-chapter source or target is skipped.
            # A for_each policy's source is the event plus a query row; the row's names are known
            # only when the query's aggregate is in this chapter, otherwise only the target is
            # checked.
            def validate_with_projections!(policies, process_managers, aggregates)
              context = WithContext.new(command_lookup(aggregates), aggregates, correlation_heads(process_managers))

              policies.each { |policy| check_policy_with!(policy, context) }
              process_managers.each do |pm|
                pm.handlers.each do |handler|
                  handler.dispatches.each { |dispatch| check_dispatch_with!(pm, handler, dispatch, context) }
                end
              end
            end

            def check_policy_with!(policy, context)
              return if policy.with_spec.to_a.empty?

              check_with_spec!(policy_with_spec(policy, context), context)
            end

            def policy_with_spec(policy, context)
              row = fan_out_row_names(policy, context.aggregates, context.lookup[policy.trigger_command])
              source_event = policy.for_each.to_s.empty? || row ? policy.on_event : nil
              WithSpec.new(policy.trigger_command, source_event, policy.with_spec, "#{policy.name}'s trigger", nil, row)
            end

            def check_dispatch_with!(process_manager, handler, dispatch, context)
              return if dispatch.with_spec.to_a.empty?

              label = "#{process_manager.name}'s dispatch #{dispatch.command_name}"
              check_with_spec!(WithSpec.new(dispatch.command_name, handler.event_type, dispatch.with_spec,
                                            label, process_manager, nil), context)
            end

            # Checks one `with:` spec: each key must be a field the target command accepts,
            # and each Symbol source must be the correlation key, the emitter's identity, or a
            # field of the event's shape. A saga leg also falls back to the opening event's shape,
            # since saga memory starts as that payload.
            def check_with_spec!(spec, context)
              target   = context.lookup[spec.command_ref]
              readable = readable_sources(spec, context.aggregates)

              spec.with_spec.each do |field, source|
                refuse_undeclared_with_field!(spec, field) if target && !command_declares?(target, field, context)
                refuse_unreadable_with_source!(spec, source, readable)
              end
            end

            def readable_sources(spec, aggregates)
              pm = spec.process_manager
              event_name = spec.event_name
              # A policy's source also carries the emitter's identity
              # (`PolicyInterpreter#emitter_identity`); a saga leg's source
              # (`SagaInterpreter#dispatch_args`) merges no such thing.
              identity = pm.nil? && event_name ? event_identity_heads_for(event_name, aggregates) : []
              shapes = [event_name && event_shape_for(event_name, aggregates),
                        pm && event_shape_for(pm.starts_on, aggregates)].compact
              Readable.new(pm&.correlates_by && pm.correlation_head, identity, shapes, spec.row_names.to_a)
            end

            def refuse_undeclared_with_field!(spec, field)
              raise Malformed,
                    "#{spec.label}'s with: names #{field.inspect}, which #{spec.command_ref} does not declare"
            end

            def refuse_unreadable_with_source!(spec, source, readable)
              return unless source.is_a?(::Symbol)
              return if source == readable.correlation || readable.identity.include?(source)
              return if readable.row.include?(source)
              return if readable.shapes.empty? || shape_reads?(readable.shapes, source)

              raise Malformed,
                    "#{spec.label}'s with: reads :#{source} off #{spec.event_name.inspect}, which does not declare it"
            end

            def shape_reads?(shapes, source)
              shapes.any? { |shape| shape.any? { |name, *| name == source } }
            end

            # Mirrors `ArgumentGate#refuse_unknown_arguments`: `:id`, the owning aggregate's
            # `identity_heads` and `Naming.reference_key(command.references)` are all legal keys
            # beside the command's own attributes.
            def command_declares?(command, field, context)
              return true if plain_argument?(command, field, context)
              return false unless command.references

              referenced = context.aggregates.find { |a| a.hecks_name == command.references }
              referenced ? referenced_key?(referenced, command, field) : false
            end

            def plain_argument?(command, field, context)
              command.attributes.any? { |a| a.name == field } || field == :id || context.correlation_heads.include?(field)
            end

            def referenced_key?(referenced, command, field)
              referenced.identity_heads.include?(field) || Naming.reference_key(command.references) == field
            end

            # A saga's `correlates_by` head is a legal `with:` key: correlation rides
            # through commands that never read it.
            def correlation_heads(process_managers)
              process_managers.filter_map { |pm| pm.correlates_by && pm.correlation_head }
            end
          end
        end
      end
    end
  end
end
