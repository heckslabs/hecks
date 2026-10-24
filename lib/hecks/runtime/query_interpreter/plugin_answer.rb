require_relative "../value"
require_relative "../wasm_plugin"

module Hecks
  module Runtime
    class QueryInterpreter
      # A query a wasm plugin answers: no hecksagon binds it, and one loaded plugin adapter says it
      # answers it. Mixed into {QueryInterpreter}, beside {OutsideAnswer}, whose argument and
      # shape checks it shares.
      module PluginAnswer
        private

        # The one plugin adapter that answers this query, or nil when none says it does.
        # Boot has already refused a query two plugins claim.
        def answering_plugin(domain, aggregate, declared)
          return nil unless declared.returns

          @registry.plugins_answering("#{domain}::#{aggregate.hecks_name}.#{declared.name}").first
        end

        # Asks the plugin, with each referenced record handed over as its stored state, and
        # builds its rows as the value object the query `returns`.
        #
        # @return [Array<Hash>] the rows as the returned value object's fields, frozen
        def answered_by_plugin(domain, aggregate, declared, args, plugin)
          asked = "#{aggregate.hecks_name}.#{declared.name}"
          refuse_offered_arguments!(declared, args, asked)
          question = "#{domain}::#{asked}"
          answer   = WasmPlugin.ask(plugin, question, plugin_arguments(domain, aggregate, declared, args))
          Freezer.deep(shaped(aggregate, declared, answer, asked))
        end

        # The arguments as plain data, a reference replaced by the state of the record it names,
        # so a plugin reads the record it was asked about without reaching the store.
        def plugin_arguments(domain, aggregate, declared, args)
          plain = Value.materialize(args)
          declared.attributes.select(&:reference?).each_with_object(plain) do |attribute, arguments|
            name = attribute.name.to_sym
            next if arguments[name].nil?

            arguments[name] = referenced_state(domain, aggregate, attribute, arguments[name])
          end
        end

        def referenced_state(domain, aggregate, attribute, id)
          target = attribute.target_aggregate || aggregate
          record = @registry.repository(domain, target).find(id) or
            raise NotFound, "#{aggregate.hecks_name}.#{attribute.name}: no #{target.hecks_name} #{id.inspect}"
          Value.materialize(record.to_h)
        end
      end
    end
  end
end
