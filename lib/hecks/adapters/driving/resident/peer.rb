require "socket"

module Hecks
  module Adapters
    module Driving
      module Resident
        # Who is on the other end of a Unix socket, by the credentials the kernel recorded when it
        # connected. Either end asks it before it sends or takes anything.
        module Peer
          # macOS: the level and option of the peer's credentials (`SOL_LOCAL`, `LOCAL_PEERCRED`).
          DARWIN = [0, 1].freeze
          # macOS: the level and option of the peer's process id (`SOL_LOCAL`, `LOCAL_PEERPID`).
          DARWIN_PID = [0, 2].freeze

          module_function

          # @param socket [UNIXSocket] a connected socket
          # @return [Integer, nil] the user id of the process on the other end, or nil when this
          #   system does not say
          def uid(socket)
            if RUBY_PLATFORM.include?("darwin")
              socket.getsockopt(*DARWIN).data.unpack("L2")[1]
            elsif defined?(Socket::SO_PEERCRED)
              socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).data.unpack("i3")[1]
            end
          rescue SystemCallError, IOError, ArgumentError
            nil
          end

          # @param socket [UNIXSocket] a connected socket
          # @return [Integer, nil] the process id of the process on the other end, or nil when this
          #   system does not say (a caller then has no process to watch)
          def pid(socket)
            if RUBY_PLATFORM.include?("darwin")
              socket.getsockopt(*DARWIN_PID).data.unpack1("i")
            elsif defined?(Socket::SO_PEERCRED)
              socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).data.unpack1("i3")
            end
          rescue SystemCallError, IOError, ArgumentError
            nil
          end

          # @return [Boolean] whether the other end is this user's process; true when the system
          #   does not say, since the socket's own directory is then all there is to go by
          def trusted?(socket)
            found = uid(socket)
            found.nil? || found == Process.uid
          end
        end
      end
    end
  end
end
