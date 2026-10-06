module Hecks
  module Storehouse
    # Answering declared queries and reading stored records directly. Extended onto `Storehouse`.
    module Querying
      # Answers one declared query.
      #
      # @param runtime [Runtime::Registry] the booted domain to query
      # @param question [String, Symbol] the query name, bare or qualified
      # @param summary [String] a one-line audit summary; required
      # @param args [Hash] the query's arguments, JSON-shaped
      # @param options [Hash] `source:`, a SOURCE_TAGS tag naming who is calling; `role:`, the
      #   caller's
      #   bound role, or nil to run unbound; `actor_id:`, the caller's identity, which requires
      #   role:
      # @return [Hash] :ok and :rows (each JSON-safe); or the refused shape
      # @raise [ArgumentError] for any other keyword
      def query(runtime:, question:, summary:, args: {}, **options)
        check_options!(options, %i[source role actor_id])
        request = Request.new(runtime: runtime, name: question, summary: summary, args: args, **options)
        request.bluebook = bluebook_for(runtime)
        audited(request, "query") { perform_query(request) }
      end

      # :nodoc:
      def perform_query(request)
        validate_caller_fields!(request)
        spec = resolve!(cli_for(request.bluebook), request.name, asking: true)
        rows = with_caller(request.role, request.actor_id) { answer(request, spec) }

        ok(summary: request.summary, rows: rows.map { |row| Doors::JsonDoor.materialize(row) }).merge(verb: spec[:command])
      end

      # :nodoc:
      def answer(request, spec)
        request.runtime.query(spec[:command], **Doors::JsonDoor.deep_symbolize(request.args))
      end

      # Reads one aggregate's stored records directly, bypassing any declared
      # query — id: answers one record, omitted answers every record.
      #
      # @param runtime [Runtime::Registry] the booted domain to read
      # @param aggregate [String, Symbol] the aggregate's declared name
      # @param summary [String] a one-line audit summary; required
      # @param id [String, Object, nil] one record's identity, or nil for every record
      # @param source [String, Symbol, nil] a SOURCE_TAGS tag naming who is calling
      # @return [Hash] :ok and, with id:, :record; without it, :count/:records; or refused
      def state(runtime:, aggregate:, summary:, id: nil, source: nil)
        bluebook = bluebook_for(runtime)
        outcome  = perform_state(runtime, bluebook, aggregate, summary, id)

        record!(bluebook.name, tool: "state", summary: summary, source: source, outcome: outcome)
        outcome
      rescue *refusal_classes => e
        outcome = refused(e, summary: summary)
        record!(bluebook&.name, tool: "state", summary: summary, source: source, outcome: outcome)
        outcome
      end

      # :nodoc:
      def perform_state(runtime, bluebook, aggregate, summary, id)
        require_summary!(summary)
        ir         = aggregate_ir!(bluebook, aggregate)
        repository = runtime.registry.repository(bluebook.name, ir)
        return ok(summary: summary, record: single_record(repository, ir, id)) if id

        records = repository.all.map { |instance| Doors::JsonDoor.materialize(instance.to_h) }
        ok(summary: summary, count: records.length, records: records)
      end

      # :nodoc:
      def single_record(repository, aggregate_ir, identity)
        instance = repository.find(identity) or
          raise Runtime::NotFound, "no #{aggregate_ir.hecks_name} found for id #{identity.inspect}"
        Doors::JsonDoor.materialize(instance.to_h)
      end
    end
  end
end
