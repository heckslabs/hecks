require_relative "site"
require_relative "source_map"
require_relative "finders"

module Hecks
  module Fuzzing
    module Mutation
      # Finds every site a mutation operator applies to in a bluebook's source.
      #
      # Each operator is a small change a reviewer would call a plausible slip: a rule dropped, a
      # comparison off by one, a guard loosened, a handler forgotten. A site is a candidate only; the
      # mutant it makes may not boot, and `Run` discards one that does not.
      module Operators
        # What each operator does, in the words a report uses.
        CATALOG = {
          drop_given:           "removes a `given` guard",
          drop_invariant:       "removes an `invariant`",
          flip_comparison:      "moves a comparison one step (`>=` to `>`, `<` to `<=`, `==` to `!=`)",
          flip_query_bound:     "swaps a query's `lt` and `gt` bound",
          drop_pattern:         "removes an attribute's `pattern:`",
          drop_one_of:          "removes an attribute's `one_of:` closed set",
          drop_sets:            "removes a `sets` line, so the command no longer records that field",
          drop_from_guard:      "removes a `from:` lifecycle guard",
          retarget_transition:  "points a lifecycle transition at a different state",
          drop_policy:          "removes a whole `policy`",
          drop_saga_transition: "removes a `process_manager` transition and its handler",
          drop_saga_dispatch:   "removes a `dispatch` a `process_manager` handler makes",
          swap_emits:           "makes a command emit a different event of the same file"
        }.freeze

        module_function

        # @param files [Hash{String => String}] bluebook source by path relative to the domain directory
        # @return [Array<Site>] every site of every operator, in file and line order
        def sites(files)
          files.sort.flat_map { |file, source| sites_in(SourceMap.new(file, source.lines)) }
        end

        # @param map [SourceMap] one bluebook
        # @return [Array<Site>] its sites
        def sites_in(map)
          map.lines.each_index.flat_map do |index|
            Finders::ALL.flat_map { |finder| finder.at(map, index) }.map do |change|
              Site.new(file: map.file, line: index + 1, original: map.lines[index], **change)
            end
          end
        end
      end
    end
  end
end
