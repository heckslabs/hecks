# [antibody-exempt: ruby/hecks/workshop/handles/aggregate_handle/behavior_methods.rb —
#  kernel-surface workshop handle : dispatches the factory keyword (and
#  transitional create alias) to the upgraded builder (first-class
#  factories phase 1).]
#
# Hecks::Workshop::AggregateHandle::BehaviorMethods
#
# Command, policy, lifecycle, transition, event subscriber, and specification
# handle methods with REPL feedback.
#
module Hecks
  class Workshop
    class AggregateHandle
      module BehaviorMethods
        # Declare a factory — a birth (first-class node, 2026-06-12).
        # `create` remains as a transitional spelling until the phase-4
        # sweep ; both route to the builder's factory keyword.
        def factory(name, produces: nil, &block)
          name = normalize_name(name)
          @builder.factory(name, produces: produces, &block)
          puts "#{name} factory created on #{@name}"
          self
        end

        def create(name, &block)
          factory(name, &block)
        end

        def command(name, &block)
          name = normalize_name(name)
          @builder.command(name, &block)
          puts "#{name} command created on #{@name}"
          self
        end

        def policy(name, &block)
          name = normalize_name(name)
          @builder.policy(name, &block)
          puts "#{name} policy created on #{@name}"
          self
        end

        def lifecycle(field, default:, &block)
          @builder.lifecycle(field, default: default, &block)
          puts "lifecycle added to #{@name} on #{field}, default: #{default}"
          self
        end

        def transition(mapping)
          lc = @builder.current_lifecycle
          if lc.nil?
            puts "no lifecycle on #{@name} — call lifecycle first"
            return self
          end
          builder = DSL::LifecycleBuilder.new(lc.field, default: lc.default)
          lc.transitions.each { |cmd, target| builder.transition(cmd => target) }
          builder.transition(mapping)
          @builder.lifecycle = builder.build
          cmd_name = mapping.keys.first
          target = mapping.values.first
          agg_name = @name
          unless @builder.commands.any? { |c| c.name == cmd_name }
            command(cmd_name) { reference_to agg_name }
          end
          puts "#{cmd_name} transition added -> #{target}"
          self
        end

        def specification(name, &block)
          name = normalize_name(name)
          @builder.specification(name, &block)
          puts "#{name} specification added to #{@name}"
          self
        end

        def on_event(event_name, async: false, &block)
          @builder.on_event(event_name, async: async, &block)
          puts "#{event_name} subscriber added to #{@name}"
          self
        end
      end
    end
  end
end
