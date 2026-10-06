module Hecks
  module Doc
    module Reference
      # The two coverage gates over a reference's prose: every live word is written about, and
      # every one has a runnable example. Extended onto `Reference`.
      module Coverage
        # Matches a runnable `ruby`/`ruby bluebook`/`ruby boot` fenced example;
        # `ruby skip` and hidden boot blocks are setup, not an example, and don't count.
        EXAMPLE_FENCE = /^```ruby(?: bluebook| boot)?[ \t]*$/

        # Whether a word's prose carries a runnable example.
        def exemplified?(prose) = prose.to_s.match?(EXAMPLE_FENCE)

        # Every live word paired with its prose; shared by both coverage gates
        # so their page-walks can't drift apart.
        def live_words(directory)
          rows = contexts.flat_map do |context|
            prose = page_prose(directory, context)
            keywords.select { |row| row[:context] == context && live?(row) }
                    .map { |row| [row[:word], context, prose[row[:word]]] }
          end
          rows.uniq { |word, context, _| [word, context] }
        end

        # @return [Hash{String, Symbol => String}] the prose committed in a context's page, or
        #   none when the page does not exist yet
        def page_prose(directory, context)
          path = File.join(directory, page_name(context))
          File.exist?(path) ? harvest(File.read(path)) : {}
        end

        # Disambiguates a word by the context it is declared in.
        def name_of(word, context) = "#{word} (#{context})"

        # The coverage gate's question: every live word with no prose yet.
        def undocumented(directory)
          live_words(directory).reject { |_word, _context, prose| prose }
                               .map { |word, context, _| name_of(word, context) }
        end

        # The second coverage gate: prose alone can go stale or describe
        # unwired behavior; a runnable example is the only doc that can go red.
        def unexemplified(directory)
          live_words(directory).reject { |_word, _context, prose| exemplified?(prose) }
                               .map { |word, context, _| name_of(word, context) }
        end

        # Both coverage gates, worded for a person: each gap section lists the words that owe it,
        # and a word missing both kinds is listed twice, one repair each.
        #
        # @param directory [String] the reference pages
        # @return [Array(Boolean, String)] whether every live word is covered, and what to print
        def coverage_report(directory)
          gaps = [[undocumented(directory), "no prose — write their sections"],
                  [unexemplified(directory), "no running example — write one in each word's own section"]]
          sections = gaps.reject { |words, _| words.empty? }.map { |words, owed| gap_section(words, owed) }
          return [true, "every live word carries prose and a running example."] if sections.empty?

          [false, sections.join]
        end

        # @return [String] the heading and list of the words that owe one kind of coverage
        def gap_section(words, owed)
          head = "#{words.size} live #{words.size == 1 ? "word carries" : "words carry"} #{owed}:\n"
          "#{head}#{words.map { |word| "  #{word}\n" }.join}\n"
        end
      end
    end
  end
end
