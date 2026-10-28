require_relative "../wasm_plugin"

module Hecks
  module Runtime
    class Registry
      # Holds a `returns` query no hecksagon binds to the one wasm plugin that says it answers it,
      # and that plugin to a module that compiles. Mixed into {Verification}, beside
      # {QueryVerification}, which asks it when a query has no other answer path.
      module PluginQueryVerification
        private

        # The one plugin adapter that says it answers a query no hecksagon binds: a `returns` query
        # is bound to it without a hecksagon line. Two plugins claiming one query is refused, since
        # the runtime will not choose between them; a hecksagon binding still overrides either.
        #
        # @param query [Bluebook::Query] the declared query
        # @param where [String] the qualified query, `"Bluebook::Aggregate.Query"`
        # @return [Bluebook::Adapter, nil] the claiming plugin, or nil when none claims it
        # @raise [WiringError] if more than one plugin claims the query
        def plugin_for(query, where)
          return nil unless query.returns

          plugins = plugins_answering(where)
          return plugins.first if plugins.size <= 1

          raise WiringError, "#{plugins.size} plugins answer #{where} (#{plugins.map(&:name).join(", ")}) — " \
                             "the runtime will not choose: bind one in the hecksagon"
        end

        # A plugin-answered query returns a value object the aggregate declares, and the plugin's
        # module compiles, so a missing or broken module stops the boot rather than the first ask.
        #
        # @raise [WiringError] if the value object is undeclared or the module will not compile
        def check_plugin_query!(aggregate, query, where)
          unless Value.value_object_for(aggregate, query.returns_name)
            raise WiringError, "#{where} returns #{query.returns_name}, but #{aggregate.hecks_name} " \
                               "declares no such value object"
          end

          WasmPlugin.compile!(plugin_for(query, where))
        end
      end
    end
  end
end
