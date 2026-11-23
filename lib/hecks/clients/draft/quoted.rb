# frozen_string_literal: true

module Hecks
  module Clients
    module Draft
      # Puts the client's own words under every projected line: the answer of the exchange the
      # line cites, as a comment. Reads the comment `Hecks::SME::DiscoveryProjection.cite` writes,
      # so a change to that format shows as a missing quote in the draft's spec, not silently.
      module Quoted
        # The cite comment: its indent, then its Point and its exchange.
        CITE = /\A(\s*)# \w+, point \d+ \(exchange (\d+)\)/

        module_function

        # @param text [String] the projected bluebook text
        # @param exchanges [Array<Hash>] the interview's exchanges, each with an `:answer` string
        # @return [String] the text with each cited exchange's answer quoted under its cite
        def call(text, exchanges)
          text.lines.flat_map { |line| [line, *quote(line, exchanges)] }.join
        end

        # @api private
        def quote(line, exchanges)
          match = CITE.match(line)
          answer = match && exchanges[match[2].to_i - 1]
          return [] unless answer

          ["#{match[1]}# #{flat(answer[:answer]).inspect}\n"]
        end

        # @api private
        def flat(words) = words.to_s.split.join(" ")
      end
    end
  end
end
