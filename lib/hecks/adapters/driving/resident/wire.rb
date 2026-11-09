require "stringio"

module Hecks
  module Adapters
    module Driving
      module Resident
        # What a launcher and its resident say to each other over the socket. A request is its own
        # length in bytes and a zero byte, then counts and fields that each end in a zero byte, so
        # nothing the other end sent is ever evaluated or deserialized: the argument list, the
        # environment, the directory and the script. The replies are one word per line.
        #
        # A line is run only after the words: the resident says `fds` once it has read the request
        # and can serve it (or `stale` when it cannot), and only then does the caller send its three
        # streams; the resident says `ready`, the caller answers `go`, and the resident ends with
        # the exit status. The streams follow the `fds` and the request is read to its stated length
        # and no further, so no read of the request can take a stream's bytes with it. A caller
        # that has gone, or gave up and booted on its own, never answers `go`, so a request that sat
        # in the queue is never run a second time.
        module Wire
          GO = "go".freeze
          FDS = "fds".freeze
          READY = "ready".freeze
          STALE = "stale".freeze
          STATUS = "status:".freeze

          # The longest field, the most fields and the most bytes a request may carry.
          MAX_FIELD = 1 << 20
          MAX_FIELDS = 20_000
          MAX_REQUEST = 8 << 20
          # The longest reply line.
          MAX_LINE = 64
          # Bytes taken from the socket at a time, at most.
          CHUNK = 8192
          # The most digits a request's stated length may have.
          MAX_DIGITS = 12
          # A digit of a stated length.
          DIGIT = /\d/

          # A request that is malformed or larger than the limits.
          class Refused < StandardError; end

          # The other end did not send or take its bytes in the time allowed.
          class Slow < IOError; end

          # One allowance of time for a whole exchange, counted from when it is made, so each step
          # of it draws on what is left and a caller that stalls in any step cannot hold the
          # resident for the sum of the steps.
          class Deadline
            # @param seconds [Numeric] how long the exchange may take
            # @param clock [#call] the time in seconds; a spec stands in
            def initialize(seconds, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
              @clock = clock
              @at = clock.call + seconds
            end

            # @return [Float] the seconds left, zero once they have run out
            def left = [@at - @clock.call, 0.0].max
          end

          # Takes fields and lines off a socket without blocking past a deadline, and without
          # taking more bytes than the limits allow.
          class Reader
            # @param io [IO] the socket
            # @param seconds [Numeric, nil] how long the whole read may take; nil waits for ever
            def initialize(io, seconds)
              @io = io
              @buffer = +""
              @deadline = seconds && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds)
              @taken = 0
            end

            # @return [String] the next field, which ends in a zero byte
            def field
              value = take("\0", MAX_FIELD)
              @taken += value.bytesize + 1
              raise Refused, "request too large" if @taken > MAX_REQUEST

              value
            end

            # @return [Integer] the next field, as a count of fields
            def count
              number = Integer(field)
              raise Refused, "too many fields" unless number.between?(0, MAX_FIELDS)

              number
            rescue ArgumentError
              raise Refused, "a count was not a number"
            end

            # @return [String] the next piece that ends in `separator`, without it
            # @raise [EOFError] when the other end stops first
            # @raise [Slow] when the deadline passes
            # @raise [Refused] when the piece grows past `longest` bytes
            def take(separator, longest)
              until (index = @buffer.index(separator))
                raise Refused, "a field was too long" if @buffer.bytesize > longest

                fill
              end
              @buffer.slice!(0, index + 1).chomp(separator).force_encoding(Encoding.default_external)
            end

            # @return [Integer] the length a request states for itself, read a byte at a time so
            #   nothing past it is taken
            # @raise [Refused] when it is not a number, or is past the limit
            def length
              digits = +""
              until (byte = exact(1)) == "\0"
                raise Refused, "a length was not a number" if digits.bytesize >= MAX_DIGITS || !byte.match?(DIGIT)

                digits << byte
              end
              Integer(digits, 10).tap { |size| raise Refused, "request too large" if size > MAX_REQUEST }
            rescue ArgumentError
              raise Refused, "a length was not a number"
            end

            # @param size [Integer] how many bytes to take
            # @return [String] exactly that many bytes, and no more taken off the socket
            # @raise [EOFError] when the other end stops first
            # @raise [Slow] when the deadline passes
            def exact(size)
              fill(size - @buffer.bytesize) while @buffer.bytesize < size
              @buffer.slice!(0, size)
            end

            private

            def fill(most = CHUNK)
              chunk = @io.read_nonblock([most, CHUNK].min, exception: false)
              raise EOFError if chunk.nil?

              chunk == :wait_readable ? wait : @buffer << chunk
            end

            def wait
              left = @deadline && (@deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
              raise Slow, "the other end was too slow" if left && left <= 0

              @io.wait_readable(left) || raise(Slow, "the other end was too slow")
            end
          end

          module_function

          # Writes a launcher line's request.
          #
          # @param io [IO] the socket
          # @param request [Hash] `argv`, `env`, `cwd` and `script`
          # @param seconds [Numeric, nil] how long the write may take; a resident that does not read
          #   makes it raise {Slow} instead of holding the launcher for ever
          def write_request(io, request, seconds: nil)
            env = request[:env].map { |name, value| "#{name}=#{value}" }
            fields = [request[:argv].size, *request[:argv], env.size, *env, request[:cwd], request[:script]]
            body = fields.map { |field| "#{field}\0" }.join
            write_within(io, "#{body.bytesize}\0#{body}", seconds)
          end

          # Reads the request to the length it states and not a byte further, so a stream the
          # caller sends after it stays on the socket for `recv_io`.
          #
          # @param io [IO] the socket
          # @param seconds [Numeric, nil] how long the whole request may take to arrive
          # @return [Hash] the request `write_request` wrote
          # @raise [EOFError] when the other end stops before the request is whole
          # @raise [Slow] when the request is not whole in time
          # @raise [Refused] when it is malformed or past the limits
          def read_request(io, seconds: nil)
            arrived = Reader.new(io, seconds)
            parse(arrived.exact(arrived.length))
          end

          # @param body [String] the counts and fields of a request
          # @return [Hash] the request
          def parse(body)
            reader = Reader.new(StringIO.new(body), nil)
            argv = Array.new(reader.count) { reader.field }
            env = Array.new(reader.count) { reader.field.split("=", 2).then { |name, value| [name, value.to_s] } }.to_h
            { argv: argv, env: env, cwd: reader.field, script: reader.field }
          end

          # Writes one reply line.
          def reply(io, word) = io.write("#{word}\n")

          # @return [String, nil] the next reply line, or nil when the other end has gone
          def read_reply(io) = io.gets&.chomp

          # @return [String] the next reply line, read within `seconds` and `MAX_LINE` bytes
          # @raise [EOFError] when the other end has gone
          # @raise [Slow] when no line arrives in time
          def read_line(io, seconds) = Reader.new(io, seconds).take("\n", MAX_LINE)

          # Writes all of `text`, giving up after `seconds` when the other end does not take it.
          def write_within(io, text, seconds)
            return io.write(text) unless seconds

            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
            until text.empty?
              wrote = io.write_nonblock(text, exception: false)
              text = wrote == :wait_writable ? waited(io, text, deadline) : text.byteslice(wrote..)
            end
          end

          def waited(io, text, deadline)
            left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Slow, "the other end did not take the request" if left <= 0 || !io.wait_writable(left)

            text
          end
        end
      end
    end
  end
end
