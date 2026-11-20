require "json"
require_relative "../instance"

module Hecks
  module Runtime
    class KernelDispatcher
      # Reads one aggregate's records from the kernel's `instances` answer, whose keys are
      # `Domain::Aggregate#id`, and hydrates each against the aggregate's IR into the
      # `Runtime::Instance` the in-process repository answers, value objects and defaults included.
      #
      # Every read is one `instances` step answering the whole store, so it grows with the store
      # until the protocol answers one record by identity.
      class Repository
        # @param client [RustBuild::KernelClient] a connected client
        # @param domain [String] the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate whose records are read
        def initialize(client, domain, aggregate)
          @client = client
          @aggregate = aggregate
          @prefix = "#{domain}::#{aggregate.name}#"
        end

        # @param id [String] the record's identity
        # @return [Runtime::Instance, nil] the record the kernel holds under `id`, or nil for none
        def find(id)
          state = held["#{@prefix}#{id}"]
          state && record(id, state)
        end

        # @param _options [Hash] the in-process repository's paging options, not sent to the kernel
        # @return [Array<Runtime::Instance>] every record of the aggregate the kernel holds
        def all(**_options)
          held.filter_map { |key, state| record(key.delete_prefix(@prefix), state) if key.start_with?(@prefix) }
        end

        # @return [Integer] how many records of the aggregate the kernel holds
        def count = all.size

        private

        def held = @client.call("instances" => true).fetch("instances", {})

        def record(id, state)
          Instance.new(aggregate: @aggregate, id: id, state: JSON.parse(JSON.generate(state), symbolize_names: true))
        end
      end
    end
  end
end
