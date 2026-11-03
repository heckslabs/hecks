# frozen_string_literal: true

require_relative "../console_capture"

module Hecks
  module Adapters
    class MainIntegration
      # What a boarding refuses to push, read from the range origin/main does not hold: a commit
      # message with an agent's attribution trailer or a release approval, and a change to the
      # version file, which is the owner's release decision. Each refusal names what it found.
      class RangeGuard
        # The message lines that stop a boarding, each with the name its refusal gives it.
        FORBIDDEN_LINES = {
          "a Co-Authored-By: Claude trailer" => /^Co-Authored-By:.*Claude/i,
          "a Claude-Session trailer"         => /^Claude-Session:/i,
          "a Release-Approved-By line"       => /^Release-Approved-By:/i
        }.freeze

        # The file whose change is a release, never boarded by an integration.
        VERSION_FILE = "lib/hecks/version.rb"

        # @param repository [Repository] the checkout the range is read in
        def initialize(repository)
          @repository = repository
        end

        # @param base [String] the commit the remote holds
        # @param tip [String] the commit a boarding would push
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming the first forbidden line or the version change
        def check!(base, tip)
          found = forbidden_line(@repository.messages(base, tip))
          refuse!(tip, "carries #{found}") if found
          refuse!(tip, "changes #{VERSION_FILE}, a release") if @repository.changed(base, tip).include?(VERSION_FILE)
        end

        private

        def forbidden_line(messages)
          FORBIDDEN_LINES.find { |_name, pattern| messages.any? { |message| message.match?(pattern) } }&.first
        end

        def refuse!(tip, why)
          raise ConsoleCapture::Failure, "boarding refused: the range up to #{tip[0, 10]} #{why}"
        end
      end
    end
  end
end
