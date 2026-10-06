module Hecks
  module Doors
    module CliRunner
      # Tails a question: asks, prints each new entry as one JSON line, and asks again from the
      # cursor the answer gave, until the reader interrupts.
      module Streaming
        # Where a stream writes and how long it runs.
        #
        # @!attribute out [r] the IO each entry's line goes to
        # @!attribute err [r] the IO a refusal goes to
        # @!attribute max_polls [r] stop after this many asks; unbounded when nil
        Sink = Struct.new(:out, :err, :max_polls)

        module_function

        # Streams the question a command line names, when it may be streamed.
        #
        # @param sink [Sink] where the stream writes
        # @return [Integer, nil] 0 or 1 for a stream, nil when `CliRunner.call` should run the line
        def run(runtime, argv, program, sink)
          plan = CliRunner.resolve(runtime, argv, program)
          words = stream_words(plan)
          words && stream_to(runtime, plan, words, sink)
        rescue Interrupt, Errno::EPIPE
          0
        rescue Runtime::NotFound, Runtime::TypeMismatch => e
          refuse(sink, "#{e.message}\n\n  #{program} #{plan[:name]} --help")
        rescue *Runtime::DOMAIN_REFUSALS => e
          refuse(sink, e.message)
        end

        # Tails the question the plan names, answering 0 when the reader ends the stream.
        def stream_to(runtime, plan, words, sink)
          tail(runtime, plan[:spec], CliDoor.arguments(plan[:spec], words), sink)
          0
        end

        # Writes a refusal to the error stream, answering status 1.
        def refuse(sink, text)
          sink.err.puts(text)
          1
        end

        # The words after the command when it is a question the launcher lists under `streams` and
        # `--stream` was given, else nil.
        def stream_words(plan)
          return if plan[:answer] || !LauncherOptions.streams?(plan[:launcher], plan[:spec])

          words, streaming = LauncherOptions.take_stream(plan[:rest])
          words if streaming
        end

        # One ask after another, each from the cursor the last gave.
        def tail(runtime, spec, args, sink)
          args   = args.merge(wait: { value: 30 }) unless args.key?(:wait)
          polls  = 0
          cursor = nil
          loop do
            row = ask(runtime, spec, args, cursor)
            emit(row, sink.out)
            cursor = row[:cursor]
            polls += 1
            break if cursor.nil? || (sink.max_polls && polls >= sink.max_polls)
          end
        end

        # The first row an ask answers, asking from `cursor` when there is one.
        def ask(runtime, spec, args, cursor)
          asked = cursor ? args.except(:from_now).merge(since: { value: cursor }) : args
          runtime.query(spec[:command], **asked).first || {}
        end

        # Prints each event of `row` as one JSON line.
        def emit(row, out)
          Array(row[:events]).each { |event| out.puts(JSON.generate(entry_line(JsonDoor.materialize(event)))) }
          out.flush
        end

        # An entry as a line: its payload, which the answer holds as JSON text, back as an object.
        def entry_line(event)
          line = JSON.parse(JSON.generate(event))
          line["payload"] = JSON.parse(line["payload"]) if line["payload"].is_a?(String)
          line
        rescue JSON::ParserError
          line
        end
      end
    end
  end
end
