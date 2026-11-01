module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The session's checkout, for reads only. A read of a checkout's state that names no checkout
        # takes the one the session set in `HECKS_CHECKOUT`; a command never does. A command names its
        # own target, because a write must land where it was asked to, not where the session last was.
        module ReadContext
          # The environment variable a session sets to name its checkout.
          VARIABLE = "HECKS_CHECKOUT".freeze

          # The aggregate whose queries read a checkout's state.
          READS = /Workspace\./

          module_function

          # @param spec [Hash] the resolved question or command
          # @param args [Hash] the parsed arguments, keyed by name
          # @param env [Hash] the process environment
          # @return [Hash] the arguments, with checkout set from the session when a read names none
          def fill(spec, args, env: ENV)
            checkout = env[VARIABLE]
            return args if checkout.nil? || checkout.empty? || args.key?(:checkout)
            return args unless spec[:kind] == :query && spec[:command].to_s.match?(READS)

            args.merge(checkout: { value: checkout })
          end
        end
      end
    end
  end
end
