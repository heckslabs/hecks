# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What a rolling fill remembers between reactions: the body of the last report, so a reaction
      # that finds the same starts and the same waits records nothing new.
      module LastRoll
        @last = nil

        # @param text [String] a rolling fill's report
        # @return [Boolean] true when the report's lines, load line aside, equal the last report's
        def self.repeat?(text)
          body = text.lines.drop(1).map(&:strip)
          same = body == @last
          @last = body
          same
        end

        # Forgets the last report.
        # @return [void]
        def self.reset! = @last = nil
      end
    end
  end
end
