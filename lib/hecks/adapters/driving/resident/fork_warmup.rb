module Hecks
  module Adapters
    module Driving
      module Resident
        # Starts the one piece of macOS system code a forked child would otherwise start for the
        # first time itself, while the resident still has it to itself.
        #
        # The `pg` gem's bundled libpq, on its first `PQconnectStart`, asks the macOS Kerberos
        # framework whether a credential cache exists (`pg_GSS_have_cred_cache`, then Kerberos'
        # `cc_initialize`). That sets up an Objective-C class, and the Objective-C runtime aborts
        # a process that does it after `fork` and before `exec`: every crash report of a resident
        # child reads "crashed on child side of fork pre-exec" with this stack. A resident child
        # that opens a Postgres connection (a spec run against Postgres, a store bound to it) does
        # exactly that. Opening one refused connection here, before any fork, leaves nothing for a
        # child to set up. Together with `OBJC_DISABLE_INITIALIZE_FORK_SAFETY` in the resident's
        # environment ({SpawnEnv}), a child depends on neither alone.
        module ForkWarmup
          # A connection that is refused at once and never reaches a server.
          PROBE = "host=127.0.0.1 port=1 connect_timeout=1".freeze

          module_function

          # @param platform [String] the platform name, `RUBY_PLATFORM` unless a spec names one
          # @param probe [#call] opens and closes the refused connection
          # @return [Boolean] whether the probe ran; false on any other platform, and when the gem
          #   or the probe is not there to run
          def run(platform: RUBY_PLATFORM, probe: method(:connect))
            return false unless platform.include?("darwin")

            probe.call
            true
          rescue LoadError, StandardError
            false
          end

          # Opens and closes one connection that is refused at once.
          #
          # @return [void]
          # @raise [LoadError] when the `pg` gem is not installed
          def connect
            require "hecks/pg_options"
            PG::Connection.connect_start(PROBE).finish
          end
        end
      end
    end
  end
end
