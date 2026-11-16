# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubListening
      # The gems the listener serves with: rack, webrick and rackup. The hecks gem does not
      # declare them, so a launcher boots without them; they are loaded only when a listener is
      # asked for, and their absence refuses that listener by name instead of failing the boot.
      module ServerGems
        # The libraries the listener requires, in load order.
        LIBRARIES = %w[rack webrick rackup/handler/webrick].freeze

        # Raised when a server gem is not installed; the listener is refused with its message.
        class Unavailable < StandardError
          # @return [String] the refusal's kind, read by a policy
          def kind = "no_server"
        end

        module_function

        # Loads the server gems and the rack app built on them.
        #
        # @return [void]
        # @raise [Unavailable] when rack, webrick or rackup cannot be loaded; nothing is bound
        def load!
          LIBRARIES.each { |library| require library }
          require_relative "receiver"
        rescue LoadError => e
          raise Unavailable, "the webhook listener needs the rack, webrick and rackup gems, " \
                             "and #{e.message}; install them (gem install rack webrick rackup) and start it again"
        end
      end
    end
  end
end
