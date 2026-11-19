# frozen_string_literal: true

require "json"
require "hecks/hecks/adapters/console_capture"

module Hecks
  module Adapters
    class FleetControl
      # The background sessions `claude agents --json --all` lists, read once per adapter.
      class Listing
        # @param shell [#capture] runs `claude`
        def initialize(shell)
          @shell = shell
        end

        # @return [Array<Hash>] every listed session, as the CLI prints it
        # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
        def entries
          @entries ||= read
        end

        # @param id [String] a short id, a full session id, or the start of either
        # @return [Hash, nil] the one session the id names, nil when none is listed
        def find(id)
          entries.find { |entry| [entry["id"], entry["sessionId"]].any? { |known| known.to_s.start_with?(id) } }
        end

        private

        def read
          result = @shell.capture("claude", "agents", "--json", "--all")
          raise ConsoleCapture::Failure, "claude could not list sessions: #{result.err.strip}" unless result.ok?

          JSON.parse(result.out)
        rescue JSON::ParserError => e
          raise ConsoleCapture::Failure, "claude listed sessions unreadably: #{e.message}"
        end
      end
    end
  end
end
