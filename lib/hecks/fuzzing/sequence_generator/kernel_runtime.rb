# frozen_string_literal: true

require "delegate"
require "json"
require_relative "../../rust_build/kernel_client"
require_relative "../../rust_build/kernel_engine"
require_relative "../../rust_build/kernel_input"
require_relative "../../runtime/kernel_dispatcher"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # The Rust kernel as the runtime a sequence is built against: a `Runtime::KernelDispatcher`
      # over a `--serve` process greeted with the domain's IR tables (defaults, needs, query needs,
      # run-required verbs), as `Differential::ServeEngine` greets it. Its `repository` also lists
      # every record (`all`), which the generator reads to bind queries to stored rows.
      class KernelRuntime < SimpleDelegator
        # Connects a kernel for an isolated copy of a domain.
        #
        # @param copy [String] the domain copy the declarations are described from
        # @param domain_path [String] the original domain, whose generated IR feeds the tables
        # @param binary [String] a kernel built for the domain's Cargo feature
        # @return [KernelRuntime] connected
        # @raise [RustBuild::KernelEngine::NotMemory] when an aggregate persists anywhere but Memory
        # @raise [RustBuild::KernelClient::Unreachable] when the kernel refuses the hello
        def self.connect(copy, domain_path, binary)
          registry = Hecks.describe(copy).registry
          RustBuild::KernelEngine.require_memory!(registry)
          client = RustBuild::KernelClient.new(binary, nil)
          greet(client, domain_path)
          new(Runtime::KernelDispatcher.new(client, registry: registry), client)
        end

        # Says hello with the domain's IR tables, and closes the client when the kernel refuses it.
        #
        # @param client [RustBuild::KernelClient] a client not yet greeted
        # @param domain_path [String] the domain whose generated IR feeds the tables
        # @return [void]
        # @raise [RustBuild::KernelClient::Unreachable] when the kernel refuses the hello
        def self.greet(client, domain_path)
          tables = RustBuild::KernelInput.tables_for(domain_path)
          answer = client.call("hello" => tables.merge("protocols" => [1]))
          return if answer["ok"]

          client.close
          raise RustBuild::KernelClient::Unreachable, answer["error"]
        end

        # @param dispatcher [Runtime::KernelDispatcher] the dispatcher the generator drives
        # @param client [RustBuild::KernelClient] its client, read for the stored records
        def initialize(dispatcher, client)
          super(dispatcher)
          @client = client
        end

        # @param domain [String] a domain name
        # @param aggregate [Bluebook::Aggregate] one of its aggregates
        # @return [Rows] a reader of the kernel's records of that aggregate
        def repository(domain, aggregate) = Rows.new(@client, "#{domain}::#{aggregate.name}")

        # One aggregate's records as the kernel's `instances` answer holds them, keyed
        # `Domain::Aggregate#id`, each with its state keyed by symbol.
        class Rows
          # @param client [RustBuild::KernelClient] a connected client
          # @param prefix [String] `Domain::Aggregate`
          def initialize(client, prefix)
            @client = client
            @prefix = "#{prefix}#"
          end

          # @param id [String] the record's identity
          # @return [Runtime::KernelDispatcher::Settled::Record, nil] the record, or nil
          def find(id) = all.find { |record| record.id == id.to_s }

          # @return [Array<Runtime::KernelDispatcher::Settled::Record>] every record, in key order
          def all
            instances = @client.call("instances" => true).fetch("instances", {})
            instances.select { |key, _| key.start_with?(@prefix) }.sort.map { |key, state| record(key, state) }
          end

          private

          def record(key, state)
            Runtime::KernelDispatcher::Settled::Record.new(
              id: key.delete_prefix(@prefix), state: JSON.parse(JSON.generate(state), symbolize_names: true)
            )
          end
        end
      end
    end
  end
end
