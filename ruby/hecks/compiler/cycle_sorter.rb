# Hecks::Compiler::CycleSorter
#
# Orders files within a dependency cycle using a greedy topological
# approach. Repeatedly selects files whose cycle-internal dependencies
# are satisfied, breaking deadlocks by choosing files with the fewest
# unsatisfied deps. Wiring files are deferred until their children
# are emitted.
#
#   sorter = CycleSorter.new(files, edges, wiring_files: Set.new)
#   sorter.sorted  # => ["/path/to/a.rb", "/path/to/b.rb"]
#
module Hecks
  module Compiler
    class CycleSorter
      # @param files [Array<String>] files in the cycle
      # @param edges [Hash{String => Set<String>}] full edge map
      # @param wiring_files [Set<String>] files that load after children
      def initialize(files, edges, wiring_files: Set.new)
        @files = files
        @edges = edges
        @wiring_files = wiring_files
        @file_set = files.to_set
        @cycle_deps = build_cycle_deps
      end

      # Returns files ordered so cycle-internal deps are respected
      # as much as possible.
      #
      # @return [Array<String>] ordered file paths
      def sorted
        result = []
        emitted = Set.new
        remaining = @files.dup

        loop do
          ready = remaining.select { |f|
            @cycle_deps[f].all? { |d| emitted.include?(d) }
          }
          ready = pick_deadlock_breakers(remaining, emitted) if ready.empty?
          non_wiring = ready.reject { |f| @wiring_files.include?(f) }
          pick = non_wiring.min || ready.min
          break unless pick
          result << pick
          emitted << pick
          remaining.delete(pick)
          break if remaining.empty?
        end

        result
      end

      private

      def build_cycle_deps
        deps = {}
        @files.each do |f|
          deps[f] = (@edges[f] || Set.new).select { |d| @file_set.include?(d) }
        end
        deps
      end

      # Picks files with fewest unsatisfied cycle deps to break deadlocks.
      def pick_deadlock_breakers(remaining, emitted)
        remaining_set = remaining.to_set
        unsatisfied = {}
        remaining.each do |f|
          unsatisfied[f] = @cycle_deps[f].count { |d|
            remaining_set.include?(d) && !emitted.include?(d)
          }
        end
        min_unsat = unsatisfied.values.min
        remaining.select { |f| unsatisfied[f] == min_unsat }
      end
    end
  end
end
