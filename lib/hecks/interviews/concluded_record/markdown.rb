module Hecks
  module Interviews
    module ConcludedRecord
      # The Markdown of a concluded interview: a heading, its participants, every exchange in the
      # order it was recorded, then every Point citing the exchange it rests on by a link.
      module Markdown
        module_function

        # @param interview [Hash] a concluded interview
        # @return [Array<String>] the record's lines
        def lines(interview)
          exchanges = Array(interview[:exchanges])
          ["# #{interview[:subject]}", "", heading_line(interview[:reference], exchanges), "",
           "## Exchanges", ""] + exchange_lines(exchanges) + ["## Points", ""] +
            point_lines(Array(interview[:points]))
        end

        # @param reference [String] the interview's reference
        # @param exchanges [Array<Hash>] its exchanges
        # @return [String] the line naming the interview and who took part
        def heading_line(reference, exchanges)
          speakers = exchanges.map { |exchange| exchange[:speaker] }.uniq
          "Interview `#{reference}`. Participants: #{speakers.join(", ")}."
        end

        # @param exchanges [Array<Hash>] the exchanges, in recorded order
        # @return [Array<String>] each exchange under a heading numbered from one
        def exchange_lines(exchanges)
          exchanges.each_with_index.flat_map do |exchange, index|
            asked = exchange[:question].to_s.empty? ? [] : ["**Question:** #{exchange[:question]}", ""]
            ["### Exchange #{index + 1}", ""] + asked + ["**#{exchange[:speaker]}:** #{exchange[:answer]}", ""]
          end
        end

        # @param points [Array<Hash>] the Points, in any state
        # @return [Array<String>] one list item a Point, or a line saying there were none
        def point_lines(points)
          return ["No points were proposed."] if points.empty?

          points.map { |point| point_line(point) }
        end

        # @param point [Hash] a Point
        # @return [String] its number, kind, state and statement, citing its exchange
        def point_line(point)
          source = point[:source]
          line = "- Point #{point[:number]}, #{point[:kind]}, #{point[:status]}, citing " \
                 "[exchange #{source}](#exchange-#{source}): #{point[:statement]}"
          point[:supersedes] ? "#{line} Supersedes point #{point[:supersedes]}." : line
        end
      end
    end
  end
end
