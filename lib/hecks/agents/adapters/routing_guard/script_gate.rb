# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    class RoutingGuard
      # The guard's script step: forwards one call of a role's session to the `Script` aggregate
      # and reads back whether it was held. A launcher call is noted (`Script.NoteHecks`), a call
      # that starts with an `Interpreter` word is attempted (`Script.Attempt`), and the bluebook's
      # policies run or hold it; this class decides neither. A call is held when the session's
      # record reads `held` after the attempt. With no session, no durable store, or a store that
      # fails, it warns and allows: the rule needs state that outlives one hook's process.
      class ScriptGate
        # Where the `Script` records live: the dispatcher that runs its commands and the
        # repository its records are read back from.
        Store = Struct.new(:dispatcher, :repository) do
          # @param verb [String] the command, `Agents::Script.<Verb>`
          # @param args [Hash] its arguments
          # @return [Object] the dispatch's result
          def dispatch(verb, **args) = dispatcher.dispatch_flat(verb, args)

          # @return [Array<Object>] every session's `Script` record
          def records = repository.all

          # @param session [String] the session's key
          # @return [Object, nil] the session's `Script` record
          def record(session) = records.find { |found| StartedWork.value(found, :session).to_s == session }
        end

        # @param registry [Runtime::Registry, nil] a boot that may hold the Agents bluebook
        # @return [Bluebook::Aggregate, nil] its `Script` aggregate
        def self.aggregate(registry)
          agents = registry&.bluebook("Agents")
          agents&.aggregates&.find { |found| found.hecks_name == "Script" }
        end

        # The store of a booted registry, when its `Script` records outlive the process.
        #
        # @param registry [Runtime::Registry, nil] the boot answering the guard
        # @return [Store, nil] nil with no registry, no `Script` aggregate, or a Memory store
        def self.store(registry)
          aggregate = aggregate(registry)
          return unless aggregate

          repository = registry.repository("Agents", aggregate)
          Store.new(Runtime::Dispatcher.new(registry), repository) unless memory?(repository)
        end

        # @param repository [Persistence::AppendOnly] the `Script` repository
        # @return [Boolean] whether it keeps its records only for this process
        def self.memory?(repository)
          kind = repository.adapter.class
          kind.name.to_s.include?("Memory")
        end

        # @param rows [#call] answers a Role value object's name with its rows
        # @param scripts [#call] answers the {Store}, or nil
        # @return [ScriptGate] a gate over the `Interpreter` rows and the `script` hint
        def self.from_rows(rows, scripts)
          hint = rows.call("RefusalHint").find { |row| row[:role] == "*" && row[:shape] == "script" }
          new(scripts: scripts, interpreters: rows.call("Interpreter").map { |row| row[:word] },
              hint: hint ? hint[:use] : "Try hecks first")
        end

        # @param scripts [#call] answers the {Store} whose `Script` records are durable, or nil
        # @param interpreters [Array<String>] the `Interpreter` rows' words
        # @param hint [String] the `script` hint a held call is refused with
        def initialize(scripts:, interpreters:, hint:)
          @scripts = scripts
          @interpreters = interpreters
          @hint = hint
        end

        # @param session [String] the Claude session making the call; blank when the hook has none
        # @param role [String] the role the session holds
        # @param text [String] the Bash command
        # @return [nil] when the call may run
        # @raise [Refused] naming the `script` hint, when the session's script is held
        def judge!(session:, role:, text:)
          return if session.to_s.empty?
          return note(session) if text.match?(LAUNCHER)
          return unless script?(text)

          refusal = attempt(session, role, text)
          raise Refused, refusal if refusal
        end

        private

        def script?(text) = @interpreters.any? { |word| text == word || text.start_with?("#{word} ") }

        def note(session)
          store&.dispatch("Agents::Script.NoteHecks", session: { value: session })
          nil
        rescue StandardError => e
          warned(e)
        end

        def attempt(session, role, text)
          return unless store

          store.dispatch("Agents::Script.Attempt", session: { value: session }, role: { value: role }, asked: { value: text })
          "#{role} routes only: #{@hint}. Refused: #{text}" if held?(session)
        rescue StandardError => e
          warned(e)
        end

        def held?(session)
          record = store.record(session)
          record && StartedWork.value(record, :verdict).to_s == "held"
        end

        def store = (@store ||= @scripts.call)

        def warned(error)
          warn "orchestrator_guard: the script rule could not answer (#{error.message}); allowing"
          nil
        end
      end
    end
  end
end
