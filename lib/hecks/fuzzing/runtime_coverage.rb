module Hecks
  module Fuzzing
    # Measures which lines (and, when stdlib Coverage is running, branches) of the Ruby runtime a
    # block reaches, as a set of stable "path:line" and "path:line:branch" strings.
    #
    # Lines come from a TracePoint, so code that was loaded before the measurement still counts.
    # Branches need stdlib Coverage started before the code was loaded; when it is not running, the
    # measurement is lines only.
    #
    # Pure observation: nothing here draws a random number, so a seed's keys are as reproducible
    # as the seed.
    module RuntimeCoverage
      module_function

      # @param roots [Array<String>] directories whose files count; anything else is ignored
      # @yield the work to measure
      # @return [Array(Object, Set<String>)] the block's value and the keys it reached
      def measure(roots: default_roots, &block)
        raise ArgumentError, "RuntimeCoverage.measure needs a block" unless block

        prefixes = roots.map { |root| File.join(File.expand_path(root), "") }
        reached = Set.new
        before = branch_snapshot
        value = trace_lines(prefixes, reached, &block)
        reached.merge(branch_keys(before, branch_snapshot, prefixes))
        [value, reached]
      end

      # The runtime this gem ships, the default measurement scope.
      def default_roots = [File.expand_path("..", __dir__)]

      def trace_lines(prefixes, reached)
        value = nil
        tracer = TracePoint.new(:line) do |point|
          path = point.path
          reached << "#{path}:#{point.lineno}" if in_roots?(path, prefixes)
        end
        tracer.enable { value = yield }
        value
      end

      # @return [Hash, nil] Coverage's branch table so far (files that report branches), or nil
      #   when Coverage is not running
      def branch_snapshot
        return unless defined?(::Coverage) && ::Coverage.respond_to?(:running?) && ::Coverage.running?

        ::Coverage.peek_result.filter_map { |path, entry| [path, entry[:branches]] if entry.is_a?(Hash) && entry[:branches] }.to_h
      end

      # Branch targets whose hit count grew between two snapshots.
      def branch_keys(before, after, prefixes)
        return [] unless before && after

        after.select { |path, _branches| in_roots?(path, prefixes) }.flat_map do |path, branches|
          grown(before[path] || {}, branches).map { |key| "#{path}:#{key}" }
        end
      end

      def in_roots?(path, prefixes) = prefixes.any? { |prefix| path.start_with?(prefix) }

      def grown(old, new)
        new.flat_map do |origin, targets|
          targets.filter_map do |target, count|
            "#{origin.drop(1).join(":")}:#{target.drop(1).join(":")}" if count > (old.dig(origin, target) || 0)
          end
        end
      end
    end
  end
end
