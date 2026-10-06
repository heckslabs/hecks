module Hecks
  module Fuzzing
    module DomainGenerator
      class Builder
        # What links aggregates to each other: references, chains, policies, roles, and the extras
        # sprinkled over every aggregate.
        module Wiring
          # Each extra shape and the probability an aggregate gets it, in the order they are drawn.
          EXTRA_SHAPES = [[:lifecycle, 0.4], [:closed_set, 0.25], [:default_attr, 0.25], [:optional_arg, 0.25],
                          [:entity, 0.2], [:query, 0.3]].freeze

          private

          def reference_attr(owner, target)
            return unless target
            return if owner["references"].include?(target["name"])

            open = creating(owner)
            add_reference!(owner, open, target)
            open["givens"] << open_given(owner, target) if target["lifecycle"] && chance?(0.5)
          end

          def add_reference!(owner, open, target)
            owner["references"] << target["name"]
            open["references"] << target["name"]
            open["sets"] << { "target"   => snake(target["name"]),
                              "requires" => ["reference:#{owner["name"]}->#{target["name"]}"] }
          end

          # A given that the referenced aggregate is open.
          def open_given(owner, target)
            { "label"    => "the #{snake(target["name"])} is open",
              "expr"     => "#{snake(target["name"])}.status == \"open\"",
              "requires" => ["lifecycle:#{target["name"]}",
                             "command_reference:#{owner["name"]}.Open->#{target["name"]}"] }
          end

          # `chain` is ordered primary, middle, root — root gets the lifecycle.
          def link_chain(chain)
            primary, middle, root = chain
            lifecycle(root)
            reference_attr(middle, root)
            reference_attr(primary, middle)
          end

          def two_hop_given(primary, middle, root)
            return unless middle && root

            path = "#{snake(middle["name"])}.#{snake(root["name"])}.status"
            creating(primary)["givens"] << {
              "label" => "the #{snake(middle["name"])}'s #{snake(root["name"])} is open", "expr" => "#{path} == \"open\"",
              "requires" => ["lifecycle:#{root["name"]}", "reference:#{middle["name"]}->#{root["name"]}",
                             "command_reference:#{primary["name"]}.Open->#{middle["name"]}"]
            }
          end

          def multi_hop_where(primary, middle, root)
            return unless middle && root

            field = "#{snake(middle["name"])}/#{snake(root["name"])}/status"
            primary["queries"] << {
              "name" => "ThroughOpen#{root["name"]}", "order_by" => primary["identity"].first,
              "wheres" => [{ "field" => field, "value" => "open",
                             "requires" => ["lifecycle:#{root["name"]}", "reference:#{middle["name"]}->#{root["name"]}",
                                            "reference:#{primary["name"]}->#{middle["name"]}"] }]
            }
          end

          # Mirrors `Referral.Reassign` (ADR 0037 F5): redeclares the reference
          # under a plain value object instead of the reference itself.
          def revalued_reference(owner, target)
            return unless target

            reference_attr(owner, target)
            field = snake(target["name"])
            vo(owner, "#{target["name"]}Handle", "string")
            requires = ["reference:#{owner["name"]}->#{target["name"]}"]
            command(owner, "Repoint", args: [{ "name" => field, "type" => "#{target["name"]}Handle" }],
                                      sets: [{ "target" => field, "requires" => requires }])
          end

          def extras(aggregate, aggregates)
            extra_shape(aggregate)
            extra_wiring(aggregate, aggregates)
          end

          def extra_shape(aggregate)
            EXTRA_SHAPES.each { |shape, probability| send(shape, aggregate) if chance?(probability) }
            emits = creating(aggregate)["emits"]
            emits << "#{aggregate["name"]}Logged" if chance?(0.15) && emits.size == 1
          end

          def extra_wiring(aggregate, aggregates)
            other = (aggregates - [aggregate]).sample(random: @random)
            reference_attr(aggregate, other) if other && chance?(0.15) && !creates_cycle?(aggregate, other, aggregates)
            assign_roles(aggregate)
            policy(aggregate) if aggregate["lifecycle"] && chance?(0.25)
          end

          # Each command has a 30% chance of being role-gated, with a drawn role.
          def assign_roles(aggregate)
            aggregate["commands"].each { |command| command["role"] = ROLES.sample(random: @random) if chance?(0.3) }
          end

          def creates_cycle?(from, to, aggregates)
            seen = Set.new
            stack = [to["name"]]
            until stack.empty?
              name = stack.pop
              return true if name == from["name"]
              next unless seen.add?(name)

              stack.concat(aggregates.find { |aggregate| aggregate["name"] == name }["references"])
            end
            false
          end

          def policy(aggregate)
            name = aggregate["name"]
            event = creating(aggregate)["emits"].first
            @policies << { "name" => "On#{event}Close", "on" => "#{name}::#{event}", "trigger" => "#{name}::Close",
                           "requires" => ["event:#{name}.#{event}", "command:#{name}.Close", "lifecycle:#{name}"] }
          end
        end
      end
    end
  end
end
