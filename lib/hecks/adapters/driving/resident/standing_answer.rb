require "socket"
require "io/wait"

module Hecks
  module Adapters
    module Driving
      module Resident
        # The launcher's answer to `PipelineBoard.snapshot` when the board is running: it asks the
        # board's `/api/snapshot` on 127.0.0.1, which draws the panel from the state it already
        # holds, prints it and ends the line, so the question costs no boot and no reads. A board
        # that is down, slow or not yet holding a state answers nothing, and the line goes on to
        # the resident or the boot as it always has.
        #
        # It uses only the standard library: it runs before `bundler/setup`, like {Client}.
        module StandingAnswer
          # The questions answered here, spelled as {Client.plain} spells them. This is the one
          # question a running server holds the answer to; it is not a table to grow.
          QUESTIONS = %w[pipelineboard.snapshot].freeze
          # Words a line may write before the question: the domain's name and the old `query` verb.
          LEADING = %w[pipelineboard query].freeze
          # The question's fields; a line with any other field is left to the launcher.
          FIELDS = %w[width colour limit].freeze
          # The board's port: the `Port` default the bluebook's `PipelineBoard.Serve` declares.
          PORT = 4747
          # The variable that names another port.
          PORT_VARIABLE = "HECKS_BOARD_PORT".freeze
          # The board's route for the panel.
          ROUTE = "/api/snapshot".freeze
          # Seconds the board has to connect, and again to answer.
          SECONDS = 2
          # Control characters stripped from the board's answer: all but tab, newline and escape.
          CONTROL = /[\x00-\x08\x0B-\x1A\x1C-\x1F\x7F]/
          # A field's value the launcher passes on: letters, digits and underscores only.
          PLAIN_VALUE = /\A\w+\z/

          module_function

          # Prints the board's answer and ends the process, when the line is the question and the
          # board answered it.
          #
          # @param argv [Array<String>] the line's words
          # @return [void] returns only when the line goes on to the launcher
          def serve(argv)
            text = answer(argv)
            return unless text

            $stdout.write(text)
            exit(0)
          end

          # @param argv [Array<String>] the line's words
          # @return [String, nil] the panel the board drew, nil when the line asks something else or
          #   no board answered in time
          def answer(argv)
            fields = asked(argv)
            fields && fetch(port, "#{ROUTE}?#{fields.map { |key, value| "#{key}=#{value}" }.join("&")}")
          rescue SystemCallError, IOError, SocketError
            nil
          end

          # @return [Hash{String => String}, nil] the question's fields, nil when the line asks
          #   something else
          def asked(argv)
            pairs, words = argv.reject { |word| word == "--wait" }.partition { |word| word.include?("=") }
            fields(pairs) if QUESTIONS.include?(question(words))
          end

          # @return [String, nil] the one word the line asks, as {Client.plain} spells it, after
          #   the leading words; nil when it writes more than one
          def question(words)
            plain = words.map { |word| plain(word) }
            plain.shift while plain.size > 1 && LEADING.include?(plain.first)
            plain.first if plain.size == 1
          end

          # @return [String] a word as {Client.plain} spells it: `Hecks::PipelineBoard.snapshot` and
          #   `pipeline_board.snapshot` are `pipelineboard.snapshot`
          def plain(word)
            bare = word.delete_prefix("Hecks::")
            bare.delete("_").downcase.chomp("!")
          end

          # @return [Hash{String => String}, nil] `width=120` and `width.value=120` alike, nil
          #   when a field is not the question's or its value is not a plain word
          def fields(pairs)
            found = pairs.to_h { |pair| pair.split("=", 2).then { |key, value| [key.delete_suffix(".value"), value] } }
            found if (found.keys - FIELDS).empty? && found.values.all?(PLAIN_VALUE)
          end

          # @return [Integer] the board's port
          def port
            Integer(ENV.fetch(PORT_VARIABLE, PORT).to_s, 10)
          rescue ArgumentError
            PORT
          end

          # @return [String, nil] the body of a 200 answer, nil for any other
          def fetch(port, target)
            Socket.tcp("127.0.0.1", port, connect_timeout: SECONDS) do |socket|
              socket.write("GET #{target} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
              body_of(read_all(socket))
            end
          end

          # @return [String, nil] everything the board wrote before it closed, nil when it took
          #   longer than the seconds it is given
          def read_all(socket)
            deadline = clock + SECONDS
            out = +""
            loop do
              left = deadline - clock
              return nil unless left.positive? && socket.wait_readable(left)

              chunk = socket.read_nonblock(65_536, exception: false)
              return out if chunk.nil?

              out << chunk if chunk.is_a?(String)
            end
          end

          # @return [String, nil] the body of a 200 answer, without control characters
          def body_of(response)
            return unless response&.start_with?("HTTP/1.1 200 ")

            body = response.split("\r\n\r\n", 2)[1].to_s.force_encoding(Encoding::UTF_8).scrub
            body.empty? ? nil : body.gsub(CONTROL, "")
          end

          def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
