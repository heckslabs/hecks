module Hecks
  module Doors
    module CliRunner
      # The text and status a command or question answers with, from the outcome the runtime gave.
      module Answers
        module_function

        # Runs a question and answers its rows, or its text when an adapter answered in text.
        #
        # @param wait [Boolean, nil] whether `--wait` was given: a report naming a gap then fails
        # @return [Array(String, Integer)] the answer and the status
        def query(runtime, spec, args, wait)
          rows = runtime.query(spec[:command], **args)
          text = text_answer(spec, rows)
          [text || JSON.pretty_generate(rows.map { |row| JsonDoor.materialize(row) }),
           wait && LauncherOptions.gap_reported?(text) ? 1 : 0]
        end

        # The answer of a command run without `--wait`: its outcome alone, since a full store dump
        # is every record there is.
        def plain(handle, extra)
          return [JSON.pretty_generate(answered(handle).merge(extra)), 0] if handle.state.nil?

          [JSON.pretty_generate({ id:     handle.id,
                                  state:  JsonDoor.materialize(handle.state),
                                  events: handle.events.map(&:name) }.merge(extra)), 0]
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
        # @return [Hash] `refused_reactions:` each with the `policy`, its `trigger` and the
        #   `reason`; empty when every reaction was delivered (or a remote host sent no per-step
        #   log), plus `reaction_defects:` when one crashed
        def refused_answer(handle)
          refused = handle.respond_to?(:refused_reactions) ? handle.refused_reactions : []
          defects = handle.respond_to?(:reaction_defects) ? handle.reaction_defects : []
          answer  = refused.empty? ? {} : { refused_reactions: refused }
          defects.empty? ? answer : answer.merge(reaction_defects: defects)
        end

        # Whether a reaction the domain refused blocks the run the handle reports.
        def blocked?(handle)
          handle.respond_to?(:blocking_reactions) && !handle.blocking_reactions.empty?
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
