# frozen_string_literal: true

require_relative "step_run/expectations"

module Hecks
  # Executes a step list against a booted domain and reports instances, events, refusals,
  # reactions, sagas and query rows: the report `Operation.run!` answers for a script, and the one
  # a mutation run compares against the script's expectations.
  #
  # A step is `{ "verb" => ..., "args" => {...} }` or `{ "query" => ..., "args" => {...} }`. A
  # refused verb and a failed query are recorded, never raised, so every step runs.
  module StepRun
    module_function

    # @param runtime [Runtime] a booted domain
    # @param steps [Array<Hash>] the steps, in order
    # @return [Hash{Symbol => Object}] `instances`, `events`, `refusals`, `reactions`, `sagas` and
    #   `queries`
    def execute(runtime, steps)
      refusals = []
      queries = []
      steps.each { |step| run_step(runtime, step, refusals, queries) }

      { instances: instances(runtime), events: events(runtime), refusals: refusals,
        reactions: runtime.reactions, sagas: runtime.sagas, queries: queries }
    end

    # @param expectations [Hash] the script's `"event_names"`, `"refusals"` and `"instances"`
    # @param report [Hash] a report `execute` answered
    # @return [Array<String>] one line per unmet expectation; empty when all are met
    def unmet(expectations, report) = Expectations.unmet(expectations, report)

    # @api private
    def run_step(runtime, step, refusals, queries)
      args = (step["args"] || {}).transform_keys(&:to_sym)
      if (question = step["query"])
        queries << ask(runtime, question, args)
        return
      end

      dispatch_verb(runtime, step["verb"], args, refusals)
    end

    # @api private
    def dispatch_verb(runtime, verb, args, refusals)
      runtime.dispatch_flat(verb, args)
    rescue StandardError => e
      refusals << { verb: verb, error: e.message.to_s }
    end

    # @api private
    def ask(runtime, question, args)
      { query: question, args: args, rows: runtime.query(question, **args) }
    rescue StandardError => e
      { query: question, args: args, error: e.message }
    end

    # @api private
    def instances(runtime)
      runtime.bluebooks.each_with_object({}) do |(domain_name, bluebook), all|
        bluebook.aggregates.each do |aggregate|
          runtime.repository(domain_name, aggregate).all.each do |record|
            all["#{domain_name}::#{aggregate.name}##{record.id}"] = record.state
          end
        end
      end
    end

    # @api private
    def events(runtime)
      runtime.events.map do |event|
        { name: event.name, aggregate: event.aggregate, id: event.id, payload: event.payload }
      end
    end
  end
end
