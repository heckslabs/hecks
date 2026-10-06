module Hecks
  module Bluebook
    module MetaValidator
      class Judge
        # Offering one declaration to the meta-domain: the dispatch itself, and the payloads of the
        # creating command, the setters, the list appenders and the sealers.
        module Dispatching
          private

          def args(pairs) = pairs.compact

          def offer(label)
            yield
          rescue Runtime::GivenNotMet, Runtime::InvariantViolation,
                 Runtime::TypeMismatch, Runtime::NotFound => e
            # NotFound is a verdict, not noise: an attribute's type is a
            # reference to its value object, so "no ValueObject with id ..."
            # is `attributes must use value-object types` refusing.
            @refusals << "#{label}: #{e.message}"
          rescue Runtime::UnknownVerb
            nil
          end

          # Wrapped in judge_bootstrapping: the walk's own values sometimes
          # arrive as raw types a real domain command would never accept,
          # and only a judge's own dispatch should relax for that.
          def send_to(verb, label, to: nil, **payload)
            Runtime::Value.judge_bootstrapping do
              offer(label) { @runtime.dispatch(verb, to: to, with: args(payload)) }
            end
          end

          def declare(plan, visit, id, extra = {})
            return unless plan.declare

            payload = declared_payload(plan, visit)
            send_to("Bluebook::#{verb_for(plan, plan.declare)}", id, to: id, **payload.merge(extra))
          end

          def declared_payload(plan, visit)
            payload = parent_link(plan, visit)
            plan.fields.each { |field| payload[field.to_sym] = declared_field(plan, visit, field) }
            payload
          end

          def parent_link(plan, visit)
            return {} unless plan.parent_key

            { plan.parent_key.to_sym => carried(plan, plan.declare, plan.parent_key, visit.parent_id) }
          end

          def declared_field(plan, visit, field)
            return v(visit.index) if field == POSITION

            carried(plan, plan.declare, field, field_value(visit.category, visit.node, field.to_sym, visit.parent_id))
          end

          # A setter whose every source is absent is not dispatched —
          # offering "" would make a rule refuse a bluebook that is
          # well-formed.
          def setters(plan, visit, receiver)
            plan.setters.each do |setter|
              payload = setter.targets.to_h do |target, argument|
                [argument.to_sym, v(setter_value(visit.category, visit.node, target))]
              end
              next if payload.values.all?(&:nil?)

              send_to("Bluebook::#{verb_for(plan, setter.verb)}", receiver[:aggregate], to: address(receiver), **payload)
            end
          end

          def appends(plan, visit, receiver)
            id = receiver[:entities].last || receiver[:aggregate]
            owner_id = owning_aggregate_ref(visit.category, id, visit.parent_id)
            plan.appends.each do |list_name, append|
              rows_for(visit.category, list_name, visit.node).each_with_index do |row, index|
                offer_append(plan, visit, receiver, Appending.new(list_name, append, row, index, id, owner_id))
              end
            end
          end

          def offer_append(plan, visit, receiver, item)
            chosen = append_for(visit.category, item.list_name, item.append, item.row, visit.node)

            send_to("Bluebook::#{verb_for(plan, chosen.verb)}", "#{item.id}##{item.list_name}[#{item.index}]",
                    to: address(receiver), **append_payload(visit, item, chosen))
          end

          def append_payload(visit, item, chosen)
            chosen.map.to_h do |field, argument|
              [argument.to_sym, appended_value(visit, item, chosen, field, argument)]
            end
          end

          # `position` is the walk index, as in `declare`: an appended
          # element is ordered by where the walk found it.
          def appended_value(visit, item, chosen, field, argument)
            return v(item.index) if field.to_s == POSITION

            carried(@plan.category(visit.category), chosen.verb, argument, cell(visit.category, item, chosen, field))
          end

          def sealers(plan, receiver)
            id = receiver[:entities].last || receiver[:aggregate]
            plan.sealers.each { |verb| send_to("Bluebook::#{verb_for(plan, verb)}", id, to: address(receiver)) }
          end
        end
      end
    end
  end
end
