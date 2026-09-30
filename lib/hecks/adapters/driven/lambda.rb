require_relative "lambda/client"
require_relative "../../ports/query/in_memory"
require_relative "../../ports/persistence/remote_runtime"
require_relative "in_memory_ordering"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # Read-side adapter for `persisted_by("Lambda")`; writes go through Runtime::RemoteDispatcher.
    # Read-only: `append`/`project` raise, since a local write would bypass remote validation.
    class Lambda
      include Ports::Persistence::RemoteRuntime

      attr_reader :aggregate

      # Resolves which Lambda function's Store to read from and builds the client that
      # reads it.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose records this adapter reads
      # @param settings [Hash{Symbol, String => Object}] world settings for the binding:
      #   `domain` (prefixes the instances lookup; default the aggregate's own name),
      #   `region` (default `"us-east-1"`) and `function` (the function name, when it is not
      #   `hecks-<domain>`), each read under a Symbol or a String key
      # @param root [String, nil] the boot's own project directory, used with `DOMAIN_NAME`
      #   to resolve which function to call; nil falls further back to `domain`
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        domain =
          if settings.key?(:domain)
            settings[:domain]
          elsif settings.key?("domain")
            settings["domain"]
          else
            aggregate.name
          end
        region = setting(settings, :region, "us-east-1")
        # Explicit function name, for deployments whose function is not `hecks-<domain>`.
        function = setting(settings, :function, nil)
        # `domain` only prefixes the instances lookup; the function to call is named by
        # DOMAIN_NAME (set in a deployed Lambda, where root is always /var/task), else by
        # root's basename, which matches hecks deploy project's stack name on a local boot.
        function_domain = ENV["DOMAIN_NAME"] || (root ? File.basename(root) : domain)
        @client = Client.new(domain: function_domain, region: region, function: function)
        @prefix = "#{domain}::#{aggregate.hecks_name}#"
      end

      # Looks up the current record for one aggregate identity, reading the Lambda's own
      # Store fresh on every call.
      #
      # @param id [String, Object] the aggregate identity, compared as `id.to_s`
      # @return [Runtime::Instance, nil] the decoded record, or nil when no record has that id
      def find(id)
        instances[id.to_s]
      end

      # Lists every stored record, in id order unless an ordering attribute is given.
      #
      # @param order_by [String, Symbol, nil] attribute (or dotted value-object path) to sort
      #   by; nil orders by id alone
      # @param direction [Symbol, String] `:asc` or `:desc`
      # @return [Array<Runtime::Instance>] the decoded records, `[]` when the Store holds none
      #   with this aggregate's own prefix
      # @raise [Runtime::WiringError] if `order_by` names no attribute of the aggregate
      def all(order_by: nil, direction: :asc)
        InMemoryOrdering.ordered(instances.values, aggregate: @aggregate, order_by: order_by, direction: direction)
      end

      # Counts the records currently held for this aggregate.
      #
      # @return [Integer] number of records
      def count = instances.size

      # Answers a declared query by filtering, ordering and paging the held records in Ruby.
      #
      # @param specification [QuerySpecification::Common::Options] the declared query
      # @param args [Hash{Symbol => Object}] values for the specification's symbolic operands
      # @param context [Hash] execution context from `Ports::Query.execute`; accepted for the
      #   port's call shape and not read
      # @return [Array<Runtime::Instance>] the matching records, `[]` when none match
      # @raise [Runtime::WiringError] if a where clause uses an operation no comparator handles
      def query(specification, args = {}, context: {})
        Ports::Query::InMemory.execute(instances.values, specification, args)
      end

      # Reads a world setting under either a Symbol or a String key, with a fallback.
      #
      # Settings arrive symbol-keyed from the DSL and string-keyed from a round-tripped export.
      #
      # @param settings [Hash] the world settings Hash to read from
      # @param key [Symbol] the setting name, tried as itself and as `key.to_s`
      # @param fallback [Object] the value to return when neither key is present
      # @return [Object] the setting's value, or `fallback` when absent
      def setting(settings, key, fallback)
        return settings[key] if settings.key?(key)
        return settings[key.to_s] if settings.key?(key.to_s)

        fallback
      end

      private

      # Never memoized: the adapter outlives requests on a warm container, so a cached read
      # would hide every later write. Keyed by the bare id after "Domain::Aggregate#".
      def instances
        @client.read.fetch("instances", {}).filter_map do |key, state|
          next unless key.start_with?(@prefix)

          [key.delete_prefix(@prefix), build_instance(key.delete_prefix(@prefix), state)]
        end.to_h
      end

      # The response is string-keyed JSON; the state codec decodes it as every adapter's read does.
      def build_instance(id, state)
        Runtime::Instance.new(aggregate: @aggregate, id: id, state: Ports::Persistence::StateCodec.decode(@aggregate, state))
      end
    end
  end
end
