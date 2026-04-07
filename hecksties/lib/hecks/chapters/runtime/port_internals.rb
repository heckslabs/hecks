# = Hecks::Chapters::Runtime::PortInternals
#
# Self-describing sub-chapter for port implementation details:
# command/repository methods, collection proxies, event recording,
# outbox/queue, ad-hoc queries, and query operators.
#
#   Hecks::Chapters::Runtime::PortInternals.define(builder)
#
module Hecks
  module Chapters
    module Runtime
      # Hecks::Chapters::Runtime::PortInternals
      #
      # Bluebook sub-chapter for port implementation details: command methods, collection proxies, and event recording.
      #
      module PortInternals
        def self.define(b)
          b.aggregate "CommandMethods", "Shared command port interface methods" do
            command("Execute") { attribute :command, String }
          end

          b.aggregate "CommandResolver", "Resolves command/event classes from names" do
            command("Resolve") { attribute :name, String }
          end

          b.aggregate "CollectionItem", "Single-item repository wrapper" do
            command("Wrap") { attribute :id, String }
          end

          b.aggregate "CollectionMethods", "Enumerable collection interface for repos" do
            command("Each") { attribute :block, String }
          end

          b.aggregate "CollectionProxy", "Lazy-loading collection with query chaining" do
            command("Chain") { attribute :scope, String }
            command("Load") { attribute :scope, String }
          end

          b.aggregate "EventRecorder", "Records events during command execution" do
            command("Record") { attribute :event_name, String; attribute :payload, String }
          end

          b.aggregate "ReferenceMethods", "Reference resolution methods for repos" do
            command("Resolve") { attribute :reference_name, String; attribute :id, String }
          end

          b.aggregate "RepositoryMethods", "Core CRUD methods for repository ports" do
            command("Create") { attribute :attributes, String }
            command("Read") { attribute :id, String }
            command("Update") { attribute :id, String; attribute :attributes, String }
            command("Delete") { attribute :id, String }
          end

          b.aggregate "MemoryOutbox", "In-memory transactional outbox" do
            command("Enqueue") { attribute :message, String }
            command("Flush") { attribute :batch_size, Integer }
          end

          b.aggregate "MemoryQueue", "In-memory message queue" do
            command("Push") { attribute :message, String }
            command("Pop") { attribute :count, Integer }
          end

          b.aggregate "AdHocQueries", "Ad-hoc query builder DSL" do
            command("Build") { attribute :expression, String }
          end

          b.aggregate "ConditionNode", "Query condition tree node" do
            command("Evaluate") { attribute :record, String }
          end

          b.aggregate "InMemoryExecutor", "Executes queries against in-memory collections" do
            command("Execute") { attribute :query, String; attribute :collection, String }
          end

          b.aggregate "ScopeMethods", "Scope composition methods for queries" do
            command("Compose") { attribute :scope_a, String; attribute :scope_b, String }
          end

          b.aggregate "Operators", "Operator registry module" do
            command("Register") { attribute :name, String; attribute :operator, String }
          end

          b.aggregate "Operator", "Base operator class for query comparisons" do
            command("Compare") { attribute :field, String; attribute :value, String }
          end

          b.aggregate "Gt", "Greater-than query operator" do
            command("Compare") { attribute :field, String; attribute :value, String }
          end

          b.aggregate "Gte", "Greater-than-or-equal query operator" do
            command("Compare") { attribute :field, String; attribute :value, String }
          end

          b.aggregate "Lt", "Less-than query operator" do
            command("Compare") { attribute :field, String; attribute :value, String }
          end

          b.aggregate "Lte", "Less-than-or-equal query operator" do
            command("Compare") { attribute :field, String; attribute :value, String }
          end

          b.aggregate "In", "Inclusion query operator" do
            command("Compare") { attribute :field, String; attribute :values, String }
          end

          b.aggregate "NotEq", "Not-equal query operator" do
            command("Compare") { attribute :field, String; attribute :value, String }
          end
        end
      end
    end
  end
end
