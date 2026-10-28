require "securerandom"
require_relative "../../../naming"
require_relative "../../../runtime/errors"
require_relative "../../../bulk/plan"
require_relative "../handle"
require_relative "query_rows"

module Hecks
  module Adapters
    module Driving
      module Ruby
        # The bulk form of an aggregate's non-creating commands (ADR 0125): a module method per
        # command that sends it to every row a query answered, through the Bulk bluebook's
        # `BulkRun`.
        #
        #     Account.freeze_account!(over: Account.open_for_customer(reference: "C-1"))
        module BulkVerbs
          # The bluebook whose `BulkRun` records every run.
          CHAPTER = "Bulk".freeze

          module_function

          # Defines `name!(over:, mode:)` on `mod` for each command of `aggregate` that does not
          # create its record. Called without `over:`, it says what the bulk form is
          # ({refuse_unaimed!}).
          #
          # @param mod [Module] the aggregate module being built
          # @param dispatcher [Runtime::Dispatcher] the booted dispatcher the runs go through
          # @param domain [String] the aggregate's bluebook
          # @param aggregate [Bluebook::Aggregate] the aggregate whose commands get a bulk form
          # @return [void]
          def define(mod, dispatcher, domain, aggregate)
            aggregate.commands.reject(&:creates?).each do |command|
              verb = "#{domain}::#{aggregate.hecks_name}.#{command.hecks_name}"
              mod.define_singleton_method("#{Naming.snake(command.hecks_name)}!") do |over: nil, mode: :best_effort|
                BulkVerbs.refuse_unaimed!(command, over)
                BulkVerbs.run(dispatcher, verb, over, mode)
              end
            end
          end

          # Defines a bare module method per query of `aggregate`, answering its rows as
          # {QueryRows}, so the answer can be handed to a bulk form as `over:`.
          #
          # @param mod [Module] the aggregate module being built
          # @param dispatcher [Runtime::Dispatcher] the booted dispatcher the queries go through
          # @param fqn [String] the aggregate's qualified name, `"Domain::Aggregate"`
          # @param aggregate [Bluebook::Aggregate] the aggregate whose queries get a method
          # @return [void]
          def define_queries(mod, dispatcher, fqn, aggregate)
            aggregate.queries.each do |query|
              verb = "#{fqn}.#{query.hecks_name}"
              mod.define_singleton_method(Naming.snake(query.hecks_name)) do |**args|
                QueryRows.new(dispatcher.query(verb, **args), verb: verb, arguments: args)
              end
            end
          end

          # Requests one bulk run and answers its record once every row has been sent.
          #
          # @param dispatcher [Runtime::Dispatcher] the booted dispatcher
          # @param verb [String] the command each row receives
          # @param over [QueryRows] what a query method answered
          # @param mode [Symbol, String] `:best_effort` or `:all_or_nothing`
          # @return [Handle] the `Bulk::BulkRun` record: `status`, and `results` per row
          # @raise [ArgumentError] if `over` is not what a query method answered
          # @raise [Runtime::WiringError] if Bulk is not attached, or the run was declined
          #   before any row was sent (a mode the store cannot honour)
          def run(dispatcher, verb, over, mode)
            refuse_unnamed_query!(over)
            bulk = bulk_aggregate(dispatcher.registry, verb)
            run = SecureRandom.uuid
            dispatcher.dispatch_flat("#{CHAPTER}::BulkRun.Request", **request(run, verb, over, mode))
            declined!(record(dispatcher, bulk, run))
          end

          # The `Request` facts for one run.
          def request(run, verb, over, mode)
            { run: { value: run }, verb: { value: verb }, over: { value: over.verb },
              arguments: Bulk::Plan.argument_rows(over.arguments), mode: { value: mode.to_s } }
          end

          # Says what the bulk form is when it is called without `over:`, the usual sign that the
          # caller meant the one-record form on a command that takes no attributes.
          #
          # @param command [Bluebook::Command] the command whose bang form was called
          # @param over [QueryRows, nil] what the caller handed `over:`
          # @raise [ArgumentError] if `over` is nil
          def refuse_unaimed!(command, over)
            return unless over.nil?

            name = "#{Naming.snake(command.hecks_name)}!"
            raise ArgumentError,
                  "#{name} on the aggregate module is the bulk form and needs over: a query, such as " \
                  "#{name.delete_suffix("!")}!(over: Aggregate.some_query). To send #{command.hecks_name} " \
                  "to one record, call #{name} on that record's handle"
          end

          def refuse_unnamed_query!(over)
            return if over.is_a?(QueryRows)

            raise ArgumentError, "over: takes what a query method answers, such as Account.open — " \
                                 "a #{over.class} names no query to run"
          end

          def bulk_aggregate(registry, verb)
            registry.bluebook(CHAPTER)&.aggregate("BulkRun") or
              raise Runtime::WiringError, "#{verb} over a query needs the Bulk bluebook: " \
                                          "add `attaches \"Bulk\"` to the domain's hecksagon"
          end

          def record(dispatcher, bulk, run)
            instance = dispatcher.registry.repository(CHAPTER, bulk).find(run)
            Handle.new(dispatcher: dispatcher, domain: CHAPTER, aggregate: bulk, instance: instance)
          end

          # The run, unless it was declined before any row was sent: that is wiring, not a
          # row's refusal.
          def declined!(handle)
            return handle unless handle.status == "declined"

            raise Runtime::WiringError, Bulk::Plan.plain(handle[:refusal]&.to_h)
          end
        end
      end
    end
  end
end
