module Hecks
  module Adapters
    module Driving
      module Resident
        # What a launcher and its resident say to each other over the socket. A request is counts
        # and fields that each end in a zero byte, so nothing the other end sent is ever evaluated
        # or deserialized: the argument list, the environment, the directory and the script. The
        # replies are one word and, at the end, the exit status.
        module Wire
          GO = "go".freeze
          STALE = "stale".freeze
          STATUS = "status:".freeze

          module_function

          # Writes a launcher line's request.
          #
          # @param io [IO] the socket
          # @param request [Hash] `argv`, `env`, `cwd` and `script`
          def write_request(io, request)
            env = request[:env].map { |name, value| "#{name}=#{value}" }
            fields = [request[:argv].size, *request[:argv], env.size, *env, request[:cwd], request[:script]]
            io.write(fields.map { |field| "#{field}\0" }.join)
          end

          # @param io [IO] the socket
          # @return [Hash] the request `write_request` wrote
          # @raise [EOFError] when the other end stops before the request is whole
          def read_request(io)
            argv = Array.new(count(io)) { field(io) }
            env = Array.new(count(io)) { field(io).split("=", 2) }.to_h
            { argv: argv, env: env, cwd: field(io), script: field(io) }
          end

          # @return [String] the next field, which ends in a zero byte
          def field(io) = io.gets("\0")&.chomp("\0") || raise(EOFError)

          # @return [Integer] the next field, as a count
          def count(io) = Integer(field(io))

          # Writes one reply line.
          def reply(io, word) = io.write("#{word}\n")

          # @return [String, nil] the next reply line, or nil when the other end has gone
          def read_reply(io) = io.gets&.chomp
        end
      end
    end
  end
end
