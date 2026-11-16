# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubListening
      # The webhook secret, read from a file only the owner writes. The listener never makes the
      # file: when it is absent or empty the listener does not start, and the refusal says where
      # the secret is looked for.
      module SecretFile
        # Where the secret is read from unless the adapter's settings name another file.
        PATH = File.join(Dir.home, ".claude", "hecks-dev", "github_webhook_secret")

        # Raised when the secret cannot be read; the listener is refused with its message.
        class Missing < StandardError
          # @return [String] the refusal's kind, read by a policy
          def kind = "no_secret"
        end

        module_function

        # @param path [String] the secret file
        # @return [String] the secret, stripped of surrounding whitespace
        # @raise [Missing] when the file is absent, unreadable or holds only whitespace
        def read(path = PATH)
          secret = File.read(path).strip
          return secret unless secret.empty?

          raise Missing, "the webhook secret file #{path} is empty; write the secret GitHub signs with into it"
        rescue SystemCallError => e
          raise Missing, "no readable webhook secret at #{path} (#{e.class}); write the secret GitHub " \
                         "signs with into it before starting the listener"
        end
      end
    end
  end
end
