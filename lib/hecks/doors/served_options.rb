require "rack"

module Hecks
  module Doors
    # What a domain's world file says it is served by: each `served_by("Adapter") { ... }` line
    # names an inbound adapter and the per-environment values it needs. The route is derived,
    # never written: a driving adapter answers at `/webhooks/<adapter name, snake-cased>` unless
    # its `path` says otherwise, so a world holds only what the domain cannot know (secret,
    # path override) and the same domain can be served differently in each environment.
    #
    # A secret is named by the environment variable that holds it, never inline.
    module ServedOptions
      VERB = "served_by".freeze

      module_function

      # @param world [Bluebook::World, nil] a domain's judged world
      # @return [Array<Hash>] one entry per `served_by` line: `adapter`, `path` and the line's settings
      def entries(world)
        return [] unless world

        world.settings.filter_map do |key, values|
          next unless key.to_s.start_with?("#{VERB}:")

          adapter = values.fetch(:adapter)
          values.merge(adapter: adapter, path: values.fetch(:path) { "/webhooks/#{snake(adapter)}" })
        end
      end

      # A Rack app mounting every `served_by` adapter the world names at its derived path.
      #
      # @param world [Bluebook::World, nil]
      # @param adapters [Hash{String => Class}] driving adapter classes by the name a world uses;
      #   each is built with `secret:` read from the environment variable the line names
      # @param env [#fetch] where secrets are read from (`ENV` in production)
      # @return [Rack::URLMap]
      # @raise [KeyError] when a line names an adapter no class answers for
      # @raise [ArgumentError] when a line names a secret variable the environment does not hold
      def rack_app(world, adapters:, env: ENV)
        routes = entries(world).to_h do |entry|
          klass = adapters.fetch(entry[:adapter])
          [entry[:path], klass.new(secret: secret_for(entry, env))]
        end
        Rack::URLMap.new(routes)
      end

      def secret_for(entry, env)
        name = entry.fetch(:secret) { raise ArgumentError, "#{entry[:adapter]} names no secret" }
        env.fetch(name) { raise ArgumentError, "#{entry[:adapter]}: environment variable #{name} is not set" }
      end

      def snake(name) = name.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end
  end
end
