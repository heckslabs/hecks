# frozen_string_literal: true

module Hecks
  module Adapters
    class GitShallowCheck
      # Reads what a red run said: the spec file that failed and the line that says why.
      class Culprit
        # A failed example in rspec's summary, or a spec file that would not load.
        SPEC_FILE = %r{^rspec \./(spec/\S+?_spec\.rb)|loading \./(spec/\S+?_spec\.rb)}

        # The line naming what went wrong.
        REASON = %r{Failure/Error:|Error}

        # @param text [String] what the run wrote
        def initialize(text)
          @text = text
        end

        # @return [String] `<spec>: <first failure line>`
        def to_s = "#{spec}: #{reason}"

        # @return [String] the first error line, else the last line the run wrote
        def reason
          lines = @text.lines.map(&:strip).reject(&:empty?)
          lines.grep(REASON).first || lines.last.to_s
        end

        private

        def spec
          found = @text.match(SPEC_FILE)
          found ? found.captures.compact.first : "the check set"
        end
      end
    end
  end
end
