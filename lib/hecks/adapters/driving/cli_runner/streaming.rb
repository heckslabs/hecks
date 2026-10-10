require "json"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Tails a question: asks again from the cursor each answer gave, printing new entries as
        # JSON lines. Extended into `CliRunner`, so its methods are the runner's own.
        module Streaming
          # Tails a question: asks, prints each new entry as one JSON line, and asks again from the
          # cursor the answer gave, until the reader interrupts. Only for a question the `launcher`
          # setting lists under `streams`, given `--stream`; `from_now` applies to the first ask
          # only.
          #
          # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
          # @param argv [Array<String>] as for `call`, with `--stream`
          # @param program [String] how the caller was invoked
          # @param out [IO] where each entry's line goes
          # @param err [IO] where a refusal goes
          # @param max_polls [Integer, nil] stop after this many asks; unbounded when nil
          # @return [Integer, nil] 0 or 1 for a stream, nil when `call` should run the line
          def stream(runtime:, argv:, program: "hecks run", out: $stdout, err: $stderr, max_polls: nil) # rubocop:disable Metrics/ParameterLists -- the keyword API is what callers pass
            plan  = resolve(runtime, argv, program)
            words = stream_words(plan)
            return unless words

            run_stream(runtime, plan[:spec], words, out, max_polls)
          rescue Interrupt, Errno::EPIPE
            0
          rescue Runtime::NotFound, Runtime::TypeMismatch => e
            refuse(err, "#{e.message}\n\n  #{program} #{plan[:name]} --help")
          rescue *Runtime::DOMAIN_REFUSALS => e
            refuse(err, e.message)
          end

          # Tails the question the line names and answers 0, the status of a stream that ended.
          def run_stream(runtime, spec, words, out, max_polls)
            tail(runtime, spec, Cli.arguments(spec, words), out, max_polls)
            0
          end

          # Prints a refusal and answers status 1.
          def refuse(err, text)
            err.puts(text)
            1
          end

          # One ask after another, each from the cursor the last gave.
          def tail(runtime, spec, args, out, max_polls)
            args   = args.merge(wait: { value: 30 }) unless args.key?(:wait)
            polls  = 0
            cursor = nil
            loop do
              row = runtime.query(spec[:command], **next_ask(args, cursor)).first || {}
              print_entries(out, row[:events])
              cursor = row[:cursor]
              polls += 1
              break if cursor.nil? || (max_polls && polls >= max_polls)
            end
          end

          # An entry as a line: its payload, which the answer holds as JSON text, back as an object.
          def entry_line(event)
            line = JSON.parse(JSON.generate(event))
            line["payload"] = JSON.parse(line["payload"]) if line["payload"].is_a?(String)
            line
          rescue JSON::ParserError
            line
          end

          # The words to ask with when the line is a stream of a streamable question; nil otherwise.
          def stream_words(plan)
            return if plan[:answer] || !LauncherOptions.streams?(plan[:launcher], plan[:spec])

            words, streaming = LauncherOptions.take_stream(plan[:rest])
            words if streaming
          end

          # The arguments of the next ask: the first as given, later ones from the cursor.
          def next_ask(args, cursor)
            cursor ? args.except(:from_now).merge(since: { value: cursor }) : args
          end

          # Prints each event of an answer as one JSON line and flushes.
          def print_entries(out, events)
            Array(events).each { |event| out.puts(JSON.generate(entry_line(Json.materialize(event)))) }
            out.flush
          end
        end
      end
    end
  end
end
