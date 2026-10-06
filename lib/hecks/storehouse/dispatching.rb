module Hecks
  module Storehouse
    # Issuing commands, singly or as a batch, and describing how to call them. Extended onto
    # `Storehouse`.
    module Dispatching
      # Issues a command, or previews it with dry_run: true.
      #
      # @param runtime [Runtime::Registry] the booted domain to dispatch against
      # @param command [String, Symbol] the command name, bare or qualified
      # @param summary [String] a one-line audit summary; required
      # @param args [Hash] the command's arguments, JSON-shaped
      # @param options [Hash] `source:` a SOURCE_TAGS tag naming the caller; `dry_run:` true to
      #   preview (a false would_succeed is no failure); `role:` the caller's bound role, nil to
      #   run unbound; `actor_id:` the caller's identity, which requires role:
      # @return [Hash] :ok plus :id/:state/:events (real) or :would_succeed/:error
      #   (dry run); or the refused shape
      # @raise [ArgumentError] for any other keyword
      def dispatch(runtime:, command:, summary:, args: {}, **)
        request = Request.new(runtime: runtime, name: command, summary: summary, args: args, **)
        request.bluebook = bluebook_for(runtime)
        audited(request, request.dry_run ? "dry_run" : "dispatch") { perform_dispatch(request) }
      end

      # :nodoc:
      def perform_dispatch(request)
        validate_caller_fields!(request)
        spec = resolve!(cli_for(request.bluebook), request.name, asking: false)
        require_caller_for_role_gated!(spec, request.role)
        envelope = command_envelope(request.args, spec)

        result = with_caller(request.role, request.actor_id) { carry_out(request, spec, envelope) }
        result.merge(verb: spec[:command])
      end

      # :nodoc:
      def command_envelope(args, spec)
        Doors::CommandRequest.normalize(Doors::JsonDoor.deep_symbolize(args),
                                        receiver:        spec[:receiver],
                                        legacy_receiver: spec[:legacy_receiver])
      end

      # :nodoc:
      def carry_out(request, spec, envelope)
        return dry_run_outcome(request.runtime, spec, envelope, summary: request.summary) if request.dry_run

        real_dispatch(request.runtime, spec, envelope, request.summary)
      end

      # :nodoc:
      def real_dispatch(runtime, spec, envelope, summary)
        result = runtime.dispatch_flat(spec[:command], envelope)
        ok(summary: summary,
           id:      result.id,
           state:   settled_state(runtime, spec, result),
           events:  result.events.map { |event| { name: event.name, payload: Doors::JsonDoor.materialize(event.payload) } })
      end

      # The record as its repository holds it once every reaction has run, which is the state the
      # dispatch resulted in; the handle's own state is the record as the command left it, so a run
      # record that a reaction completes would otherwise read as `requested`. Falls back to the
      # handle's state for a command that belongs to no top-level aggregate or whose record cannot
      # be
      # read.
      # :nodoc:
      def settled_state(runtime, spec, result)
        return if result.state.nil?

        Doors::JsonDoor.materialize(settled_record(runtime, spec, result) || result.state)
      end

      # :nodoc:
      def settled_record(runtime, spec, result)
        bluebook = bluebook_for(runtime)
        aggregate = top_level_aggregate(bluebook, spec[:command])
        aggregate && runtime.registry.repository(bluebook.name, aggregate)&.find(result.id)&.to_h
      end

      # :nodoc:
      def top_level_aggregate(bluebook, command)
        head = command.split("::", 2).last
        return unless head.count(".") == 1

        bluebook.aggregates.find { |candidate| candidate.hecks_name == head.split(".").first }
      end

      # What a caller needs to call each of the named commands: its qualified name, the role it
      # declares, what it does, and its argument names, a trailing `*` marking a required one.
      #
      # @param runtime [Runtime::Dispatcher] the booted domain
      # @param names [Array<String>] short or qualified command names
      # @return [Array<String>] one line per name that resolves, in order
      def command_guide(runtime, names)
        cli = cli_for(bluebook_for(runtime))
        names.filter_map do |name|
          guide_line(name, resolve!(cli, name.to_s, asking: false))
        rescue Runtime::NotFound
          nil
        end
      end

      # :nodoc:
      def guide_line(name, spec)
        arguments = spec[:arguments].map { |arg| arg[:path].split(".").first + (arg[:required] ? "*" : "") }
        "#{name} (role #{spec[:role] || "none"}): #{spec[:summary]}. Arguments: #{arguments.uniq.join(", ")}"
      end

      # :nodoc:
      def dry_run_outcome(runtime, spec, envelope, summary:)
        flat = flatten_legacy(envelope, spec[:receiver], spec[:legacy_receiver])
        runtime.dry_run?(spec[:command], **flat)
        ok(summary: summary, would_succeed: true)
      rescue Runtime::WiringError, *Runtime::DOMAIN_REFUSALS => e
        ok(summary: summary, would_succeed: false, error: e.message)
      end

      # Dispatches a sequence of commands as one call, through dispatch itself: same audit log
      # line per step. Runs every step even after a refusal, since a later step naming a
      # since-refused record refuses honestly on its own.
      #
      # @param runtime [Runtime::Registry] the booted domain to dispatch against
      # @param steps [Array<Hash>] each step's command/args, JSON-shaped
      # @param summary [String] a one-line audit summary; required
      # @param options [Hash] `source:`, a SOURCE_TAGS tag naming who is calling; `role:`, the
      #   caller's bound role, or nil to run unbound; `actor_id:`, the caller's identity, which
      #   requires role:
      # @return [Hash] :ok (true only if every step's own :ok was true), :results
      # @raise [ArgumentError] for any other keyword
      def dispatch_batch(runtime:, steps:, summary:, **options)
        check_options!(options, %i[source role actor_id])
        run_batch(runtime, steps, summary, options)
      end

      # :nodoc:
      def run_batch(runtime, steps, summary, options)
        require_summary!(summary)
        results = Array(steps).map { |raw| batch_step(runtime, raw, summary, options) }
        { ok: results.all? { |r| r[:ok] }, summary: summary, results: results }
      rescue *refusal_classes => e
        refused(e, summary: summary)
      end

      # :nodoc:
      def batch_step(runtime, raw, summary, options)
        step = Doors::JsonDoor.deep_symbolize(raw)
        dispatch(runtime: runtime, command: step[:command], args: step[:args] || {}, summary: summary, **options)
      end
    end
  end
end
