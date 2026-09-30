# frozen_string_literal: true

require_relative "qa_tool"

module Hecks
  module Adapters
    # The `AngleTools` port's adapter: answers `Angle`'s query by running the seed of the backlog.
    class AngleTools < QaTool
      # @return [String] each starting lead's outcome: proposed, or already on file
      def seed
        run_command("qa_seed_angles")
      end
    end
  end
end
