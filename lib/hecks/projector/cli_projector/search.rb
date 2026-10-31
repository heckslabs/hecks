module Hecks
  module Projector
    module CliProjector
      # `hecks search <word>` (ADR 0163, plan step 20): the commands and queries whose call or
      # description holds a word, each as the call to type, grouped by module when the bluebook
      # declares one and by aggregate otherwise. It reads the listing's own specs and labels, so
      # a renamed command is found under its new name without a second index.
      module Search
        # The lines answering a search, or nil when nothing matches.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook whose modules group the hits
        # @param commands [Hash{Symbol => Hash}] the projected command specs
        # @param questions [Hash{Symbol => Hash}] the projected query specs
        # @param options [Hash{Symbol => Object}] the listing's options; `:all` includes the
        #   internal commands and queries, as `--all` does
        # @param word [String] the word to find, matched case-insensitively
        # @return [Array<String>, nil] the lines to print, or nil when no command or query matches
        def search_lines(bluebook, commands, questions, options, word)
          hits = [commands, questions].flat_map { |specs| hits_in(specs, options, word.downcase) }
          return if hits.empty?

          ranked_lines(bluebook, hits)
        end

        # The hits in rank order, name matches first, each rank under its module or aggregate.
        def ranked_lines(bluebook, hits)
          width = hits.map { |hit| label(hit[:spec]).length }.max
          hits.sort_by { |hit| [hit[:rank], label(hit[:spec])] }
              .partition { |hit| hit[:rank].zero? }
              .flat_map { |part| grouped_lines(bluebook, part, width) }
        end

        # The hits of one rank, under a heading per module or aggregate, in the order they appear.
        def grouped_lines(bluebook, hits, width)
          hits.group_by { |hit| group_name(bluebook, hit[:spec]) }.flat_map do |group, members|
            ["#{group}:", *members.map { |hit| hit_line(hit[:spec], width) }]
          end
        end

        # The matching specs of one table with the rank of each: 0 for a match on the call,
        # 1 for a match on the description only. Internal specs stay out unless `:all` is given.
        def hits_in(specs, options, needle)
          CliAudience.audience_specs(specs, options).values.filter_map do |spec|
            next if spec[:internal] && !options[:all]

            rank = rank_of(spec, needle)
            { spec: spec, rank: rank } if rank
          end
        end

        # Where a spec matches the needle: its call (0), its description (1), or nowhere (nil).
        def rank_of(spec, needle)
          return 0 if label(spec).downcase.include?(needle)
          return 1 if spec[:summary].to_s.downcase.include?(needle)

          nil
        end

        # The heading a hit sits under: its module's name when a module of the bluebook groups its
        # aggregate, else the aggregate's own name.
        def group_name(bluebook, spec)
          row = bluebook.modules.find { |module_row| module_row.aggregate == spec[:group] }
          row ? Naming.snake(row.name) : spec[:group]
        end

        # One hit: the call to type, padded to the widest, then what it does in one sentence.
        def hit_line(spec, width)
          text = spec[:kind] == :command ? spec[:summary].to_s : first_sentence(spec[:summary].to_s)
          "  #{label(spec).ljust(width)}  #{text}"
        end
      end
    end
  end
end
