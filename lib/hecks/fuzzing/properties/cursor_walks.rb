module Hecks
  module Fuzzing
    module Properties
      # The property that holds a cursor query's pages to its unpaged answer (ADR 0130). Mixed into
      # {Querying}, whose recomputation helpers it reads.
      module CursorWalks
        # Walks every cursor query's pages and holds the walk to the unpaged query: the same rows,
        # in the same order, none twice, each page within the page size and every page but the
        # last full.
        #
        # The unpaged answer is recomputed from `history[:instances]` through the shared ordering,
        # so the property does not check the pages against the keyset rule they were cut by. The
        # replay walked each query at its own page size and again one row at a time, on whichever
        # adapter the replay booted, so the property holds on each of them.
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true, or a message naming each walk that differs
        def cursor_walk_yields_the_unpaged_rows(history)
          bluebooks = history.fetch(:bluebooks)
          offenders = history.fetch(:queries).flat_map { |asked| cursor_offenses(bluebooks, asked) }
          offenders.empty? || offenders.join("; ")
        end

        # The messages for one cursor ask whose walks differ from the unpaged rows.
        def cursor_offenses(bluebooks, asked)
          return [] unless asked[:pages]

          declared = query_for_verb(bluebooks, asked[:query])
          args = normalized_args(bluebooks, asked, declared)
          expected = ordered_rows(eligible_rows_for(bluebooks, asked, declared, args), declared)
          asked[:pages].filter_map { |walk| walk_offense(asked, declared, args, walk, expected) }
        end

        def walk_offense(asked, declared, args, walk, expected)
          pages = walk.fetch(:pages)
          size = [resolve_paging_value(declared.limit.value, args).to_i, walk[:page_size] || Float::INFINITY].min
          return if pages.flatten(1) == expected && pages_fit?(pages, size)

          "#{asked[:query]} #{args.inspect} walked at page size #{size}: #{walk_summary(pages, expected)}"
        end

        def walk_summary(pages, expected)
          "#{pages.map(&:length).inspect} rows a page, #{row_ids(pages.flatten(1)).inspect} in all, " \
            "but the unpaged query is #{row_ids(expected).inspect}"
        end

        def row_ids(rows) = rows.map { |row| row[:id] }

        # Every page holds at most `size` rows and every page but the last holds exactly that many.
        def pages_fit?(pages, size)
          pages.all? { |page| page.length <= size } && pages[0...-1].all? { |page| page.length == size }
        end
      end
    end
  end
end
