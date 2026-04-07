# = Hecks::Chapters::Runtime::Ports
#
# Self-describing sub-chapter for runtime ports: commands, queries,
# repository, event bus, queue, and domain mixins (Command, Model,
# Query, Specification).
#
#   Hecks::Chapters::Runtime::Ports.define(builder)
#
module Hecks
  module Chapters
    module Runtime
      # Hecks::Chapters::Runtime::Ports
      #
      # Bluebook sub-chapter for runtime ports: commands, queries, repository, event bus, and domain mixins.
      #
      module Ports
        def self.define(b)
          b.aggregate "EventBus", "Publish-subscribe event dispatch" do
            command("Publish") { attribute :event_name, String }
            command("Subscribe") { attribute :event_name, String }
          end

          b.aggregate "CommandBus", "Routes commands to handlers with middleware" do
            command("Dispatch") { attribute :command_name, String }
            command("AddMiddleware") { attribute :middleware_name, String }
          end

          b.aggregate "CommandRunner", "Executes a single command through the pipeline" do
            command("Run") { attribute :command_name, String }
          end

          b.aggregate "Repository", "Aggregate persistence port with collection proxy" do
            command("Create") { attribute :aggregate_name, String }
            command("Find") { attribute :id, String }
            command("Delete") { attribute :id, String }
          end

          b.aggregate "QueryBuilder", "Composable query DSL with in-memory executor" do
            command("Where") { attribute :field, String; attribute :value, String }
            command("OrderBy") { attribute :field, String }
          end

          b.aggregate "QueuePort", "Async command dispatch via in-memory queue" do
            command("Enqueue") { attribute :command_name, String }
            command("Process") { attribute :batch_size, Integer }
          end

          b.aggregate "CommandMixin", "Included into generated command classes" do
            command("Execute") { attribute :attributes, String }
          end

          b.aggregate "ModelMixin", "Included into generated aggregate/entity classes" do
            command("Initialize") { attribute :attributes, String }
          end

          b.aggregate "QueryMixin", "Included into generated query classes" do
            command("Call") { attribute :params, String }
          end

          b.aggregate "SpecificationMixin", "Predicate objects for domain rules" do
            command("Satisfied") { attribute :candidate, String }
          end

          b.aggregate "AttachmentMethods", "File attachment support for aggregates" do
            command("Attach") { attribute :field, String; attribute :file, String }
          end

          b.aggregate "Commands", "Wires command dispatch infrastructure onto aggregate classes at boot" do
            command("Bind") { attribute :klass, String; attribute :aggregate, String }
            command("BindShortcuts") { attribute :klass, String; attribute :aggregate, String }
          end

          b.aggregate "Querying", "Wires query services (scopes, ad-hoc queries, operators) onto aggregate classes" do
            command("Bind") { attribute :klass, String; attribute :aggregate, String }
          end

          b.aggregate "Persistence", "Wires CRUD, collection proxy, reference, and event recording onto aggregates" do
            command("Bind") { attribute :klass, String; attribute :aggregate, String; attribute :repo, String }
            command("BindEventRecorder") { attribute :klass, String; attribute :recorder, String }
          end

          b.aggregate "Outbox", "Reliable event publishing via transactional outbox pattern" do
            command("Enable") { attribute :enabled, String }
          end

          b.aggregate "Queue", "Event queue publishing (RabbitMQ, file, custom adapter)" do
            command("Enable") { attribute :adapter, String }
          end
        end
      end
    end
  end
end
