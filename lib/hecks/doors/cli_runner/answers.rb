require "json"

module Hecks
  module Doors
    module CliRunner
      # Runs one resolved command or question and shapes what it answers. Extended into
      # `CliRunner`.
      module Answers
        # What a dispatch needs beyond the spec: the parsed arguments, whether `--wait` was given,
        # and the chapter and launcher setting the command belongs to.
        Invocation = Struct.new(:args, :wait, :bluebook, :launcher)

        # Parses one resolved command's arguments, runs it as a query or command, and turns the
        # outcome, or the domain's refusal, into `[json_or_message, status]`. With `--wait`, a
        # question whose report names a gap (`LauncherOptions.gap_reported?`) answers status 1.
        #
        # @param bluebook [Bluebook::Chapter] the chapter the command belongs to
        # @param launcher [Hash, nil] the chapter's `launcher` world setting; nil when not opted in
        def dispatch(runtime, spec, name, rest, program, asking, bluebook: nil, launcher: nil) # rubocop:disable Metrics/ParameterLists -- the signature is what `call` passes
          args, wait = command_line(spec, rest, launcher)
          return answer_query(runtime, spec, args, wait) if spec[:kind] == :query

          run_command(runtime, spec, Invocation.new(args, wait, bluebook, launcher))
        rescue Runtime::NotFound, Runtime::TypeMismatch => e
          # A bad argument and a missing record both need the same next step: read the help.
          ["#{e.message}\n\n  #{program} #{"query " if asking}#{name} --help", 1]
        rescue *Runtime::DOMAIN_REFUSALS => e
          # The refusal is the chapter's own sentence, verbatim.
          [e.message, 1]
        rescue StandardError => e
          # So is a wrapped tool's, when a question's adapter refuses to answer.
          raise unless tool_refusal?(e)

          [e.message, 1]
        end

        # The parsed arguments of a command line and whether to wait for the reactions.
        def command_line(spec, rest, launcher)
          rest, wait = LauncherOptions.take_wait(spec, rest) if launcher
          [CliDoor.arguments(spec, rest), wait || LauncherOptions.settled?(launcher, spec)]
        end

        # Whether the error is a wrapped tool's refusal. Matched by name: the adapters belong to the
        # Hecks chapter, which a client's runtime never loads.
        def tool_refusal?(error)
          error.class.ancestors.map(&:name).include?(CliRunner::TOOL_REFUSAL)
        end

        # Runs a command and answers its outcome, settled when `--wait` asks for it.
        def run_command(runtime, spec, invocation)
          args, minted = LauncherOptions.run_key(runtime, spec, invocation.args, invocation.launcher)
          handle = runtime.dispatch_flat(spec[:command], normalized_request(spec, args))
          extra  = refusals_and_run(handle, minted)
          return settled(runtime, spec, handle, invocation.bluebook, invocation.launcher, extra) if invocation.wait

          [JSON.pretty_generate(outcome(handle, extra)), 0]
        end

        # The request a command takes from its parsed arguments.
        def normalized_request(spec, args)
          CommandRequest.normalize(args, receiver: spec[:receiver], legacy_receiver: spec[:legacy_receiver])
        end

        # The refused reactions of the dispatch, led by the minted run key when one was.
        def refusals_and_run(handle, minted)
          extra = refused_answer(handle)
          minted ? { run: minted }.merge(extra) : extra
        end

        # Answers with only this command's outcome; a full store dump is every record there is.
        def outcome(handle, extra)
          return answered(handle).merge(extra) if handle.state.nil?

          { id: handle.id, state: JsonDoor.materialize(handle.state), events: handle.events.map(&:name) }.merge(extra)
        end

        # Runs a question and answers its rows, or its text when an adapter answered in text.
        #
        # @param wait [Boolean, nil] whether `--wait` was given: a report naming a gap then fails
        # @return [Array(String, Integer)] the answer and the status
        def answer_query(runtime, spec, args, wait)
          rows = runtime.query(spec[:command], **args)
          text = text_answer(spec, rows)
          [text || JSON.pretty_generate(rows.map { |row| JsonDoor.materialize(row) }),
           wait && LauncherOptions.gap_reported?(text) ? 1 : 0]
        end

        # The text a query answered by a port gave, when that is the whole answer.
        #
        # A query declared `returns Document` (one value object of the single String attribute
        # `text`) answers one document; printing it raw keeps the document (JSON, Markdown,
        # sentences) readable and pipeable instead of quoted inside another JSON document. What a
        # query declares decides it, not how many rows came back: any other query prints JSON,
        # so a script reading it sees an array whether it held one row or two.
        #
        # @param spec [Hash] the question's projected spec
        # @param rows [Array<Hash>] the query's rows
        # @return [String, nil] the text, or nil when the query does not return a Document
        def text_answer(spec, rows)
          return unless spec[:returns] == "Document" && rows.length == 1 && rows.first.keys == [:text]
          return unless rows.first[:text].is_a?(String)

          rows.first[:text]
        end

        # The reactions one dispatch caused that the domain refused, as `refused_reactions:`.
        #
        # A policy's trigger that a `given` refuses is not the command's own refusal: the command
        # has already persisted. The dispatch result carries them (`Result#refused_reactions`);
        # without this the answer would say nothing of it. A defect (a crash) is shown apart, as
        # `reaction_defects:`, and fails `--wait`.
        #
        # @param handle [Runtime::Dispatcher::Result, Runtime::RemoteDispatcher::Result] the outcome
        # @return [Hash] `refused_reactions:` each with the `policy`, its `trigger`, the `reason`;
        #   empty when every reaction was delivered (or a remote host sent no per-step log), plus
        #   `reaction_defects:` when one crashed
        def refused_answer(handle)
          refused = handle.respond_to?(:refused_reactions) ? handle.refused_reactions : []
          defects = handle.respond_to?(:reaction_defects) ? handle.reaction_defects : []
          answer  = refused.empty? ? {} : { refused_reactions: refused }
          defects.empty? ? answer : answer.merge(reaction_defects: defects)
        end

        # Shapes a port operation's outcome, which has no state: each event with its full payload.
        #
        # The answer lives only in the payloads, so names alone would drop it. Exit status stays 0
        # for refusal events too, since a healthy no is an answer, not a misuse.
        def answered(handle)
          # A port operation hydrates no instance, so the handle's `id` is nil by design.
          { id:     handle.id || handle.events.first&.id,
            events: handle.events.map do |event|
              { name: event.name, payload: JsonDoor.materialize(event.payload) }
            end }
        end
      end
    end
  end
end
