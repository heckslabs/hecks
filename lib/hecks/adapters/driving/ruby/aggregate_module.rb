require_relative "../../../bluebook/dsl/hecksagon_builder"
require_relative "../../../bluebook/dsl/world_builder"
require_relative "../../../bluebook/dsl/domain_port_builder"
require_relative "../../../bluebook/dsl/const_shim"
require_relative "../../../bluebook/dsl/binding_proxy"
require_relative "../../../bluebook/hecksagon"
require_relative "../handle"
require_relative "bulk_verbs"
require_relative "query_rows"
require_relative "../../../naming"
require_relative "aggregate_module/hooks"

module Hecks
  module Adapters
    module Driving
      module Ruby
        # One aggregate module: creating verbs and queries as module methods, CRUD
        # delegation, and the `.hecksagon` binding/port hooks it lands on.
        module AggregateModule
          # Builds one aggregate module: creating-command methods, query methods,
          # find/all/count/events, project/docs/narrate, and the port/binding hooks.
          #
          # Each concern is a helper that defines its methods on the module and closes over the same
          # arguments. The hooks live in `AggregateModule::Hooks`, which the module's blocks call by name.
          def aggregate_module(dispatcher, domain, aggregate)
            fqn = "#{domain}::#{aggregate.hecks_name}"
            mod = Module.new

            warn_shadowed_attributes(aggregate)
            define_surface(mod, dispatcher, domain, aggregate, fqn)
            Hooks.define_port_hook(mod, domain, aggregate, fqn)
            Hooks.define_ask_via(mod, domain, aggregate)
            Hooks.define_method_missing(mod, fqn)
            Hooks.define_respond_to_missing(mod)
            Hooks.define_const_missing(mod, aggregate)
            mod
          end

          private

          # Warns for each attribute that shadows a built-in, since no reader is defined for it.
          def warn_shadowed_attributes(aggregate)
            aggregate.attributes.each do |attribute|
              next unless RESERVED.include?(attribute.name.to_sym)

              warn "[hecks] #{aggregate.hecks_name}##{attribute.name} shadows a built-in — no reader defined"
            end
          end

          # The module's everyday surface: its commands, its identity, its projections, and its reads.
          def define_surface(mod, dispatcher, domain, aggregate, fqn)
            define_creating_commands(mod, dispatcher, domain, aggregate, fqn)
            define_reflection(mod, dispatcher, domain, aggregate, fqn)
            define_names(mod, aggregate)
            define_projection(mod, aggregate)
            define_narration(mod, dispatcher, domain, aggregate)
            define_finders(mod, dispatcher, domain, aggregate)
            define_tallies(mod, dispatcher, domain, aggregate, fqn)
          end

          # `!` marks a creating command (Ruby's mutate-and-may-refuse convention).
          # Without it, a query sharing the same business name (e.g. Account's
          # "Open") would collide with the creating command's own bare name.
          def define_creating_commands(mod, dispatcher, domain, aggregate, fqn)
            aggregate.commands.select(&:creates?).each do |command|
              mod.define_singleton_method("#{Naming.snake(command.hecks_name)}!") do |**args|
                Handle.new(dispatcher: dispatcher, domain: domain, aggregate: aggregate,
                           instance: dispatcher.dispatch("#{fqn}.#{command.hecks_name}", with: args).instance)
              end
            end

            # Every other command's bang form sends it to every row a query answered (ADR 0125).
            BulkVerbs.define(mod, dispatcher, domain, aggregate)
            # A query is a bare module method (no `!`): it reads and returns the raw rows
            # `dispatcher.query` answers, as `QueryRows` so a bulk run can name the query.
            BulkVerbs.define_queries(mod, dispatcher, fqn, aggregate)
          end

          # The module's own identity: its FQN, its IR, and its repository.
          def define_reflection(mod, dispatcher, domain, aggregate, fqn)
            mod.define_singleton_method(:fqn) { fqn }
            mod.define_singleton_method(:ir)  { aggregate }
            mod.define_singleton_method(:repository) { dispatcher.registry.repository(domain, aggregate) }
          end

          # The names of the aggregate's commands and queries.
          def define_names(mod, aggregate)
            mod.define_singleton_method(:commands) do
              aggregate.commands.map { |c| "#{Naming.snake(c.hecks_name)}!" }.sort
            end
            mod.define_singleton_method(:queries) { aggregate.queries.map { |q| Naming.snake(q.hecks_name) }.sort }
          end

          # Every construct emits its own IR, so an aggregate is a legitimate
          # `project` target too. A bluebook-scoped target refuses here via
          # `Projector.admits!` rather than answering a confidently empty result.
          def define_projection(mod, aggregate)
            mod.define_singleton_method(:project) do |target, out: nil, **options|
              key      = Projector.key_for(target)
              artifact = Projector.call(key, bluebook: aggregate, options: options)
              return artifact unless out

              Projector.write(artifact, out, as: Projector.emits_for(key))
            end
          end

          # This bluebook's own `:docs` and `:narrate` projections, narrowed to this aggregate.
          def define_narration(mod, dispatcher, domain, aggregate)
            mod.define_singleton_method(:docs) do |**options|
              Projector.call(:docs, bluebook: dispatcher.registry.bluebook(domain),
                                    options:  options.merge(aggregate: aggregate.hecks_name))
            end
            mod.define_singleton_method(:narrate) do |**options|
              Projector.call(:narrate, bluebook: dispatcher.registry.bluebook(domain),
                                       options:  options.merge(aggregate: aggregate.hecks_name))
            end
          end

          # `find` and `all` read the aggregate's repository and wrap each instance in a handle.
          def define_finders(mod, dispatcher, domain, aggregate)
            mod.define_singleton_method(:find) do |id|
              found = dispatcher.registry.repository(domain, aggregate).find(id)
              found && Handle.new(dispatcher: dispatcher, domain: domain, aggregate: aggregate, instance: found)
            end

            mod.define_singleton_method(:all) do |**opts|
              repository = dispatcher.registry.repository(domain, aggregate)
              repository.all(**opts).map do |instance|
                Handle.new(dispatcher: dispatcher, domain: domain, aggregate: aggregate, instance: instance)
              end
            end
          end

          # `count` and `events` read what the aggregate has stored and emitted.
          def define_tallies(mod, dispatcher, domain, aggregate, fqn)
            mod.define_singleton_method(:count)  { dispatcher.registry.repository(domain, aggregate).count }
            mod.define_singleton_method(:events) { dispatcher.events.select { |event| event.aggregate == fqn } }
          end
        end
      end
    end
  end
end
