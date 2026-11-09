# frozen_string_literal: true

require "hecks/vocabulary"

module Hecks
  module Adapters
    class GitRehearsal
      # What a rehearsal of a scope covered of CI. The `RequiredCheck` rows are what CI runs; the
      # scope's `covers` column names the ones it runs at least in part. The rest it did not run,
      # so a green rehearsal never claims a green CI.
      class Coverage
        # How a covered check is run here, where that is less than CI runs.
        PARTIAL = { "rspec" => "rspec (impacted files only)" }.freeze

        # @param scope [String] a `RehearsalScope` row's name
        # @raise [KeyError] when no `RehearsalScope` row has that name
        def initialize(scope)
          @covers = covers(scope)
        end

        # @return [String] the checks run in part, the checks not run, and where to read the rest
        def line
          "ran in part: #{@covers.map { |name| PARTIAL.fetch(name, name) }.join(", ")}; " \
            "not run: #{(required - @covers).join(", ")}; green here is not green CI: " \
            "EarlyCi (the ci/<branch> draft) runs them"
        end

        private

        def required = Vocabulary.rows("RequiredCheck").map { |row| row["name"] }

        def covers(scope)
          row = Vocabulary.rows("RehearsalScope").find { |each| each["name"] == scope }
          raise KeyError, "no rehearsal scope #{scope.inspect}" unless row

          row["covers"].split(",")
        end
      end
    end
  end
end
