# frozen_string_literal: true

module Hecks
  module Adapters
    # The `BehaviorsCounting` port's adapter for `BehaviorsCoverage`: pairs each `*.bluebook` under a
    # root with the `.behaviors` file of the same name beside it, and answers the names of those
    # without one and the counts. It decides nothing about them.
    class BehaviorsCounting
      # Directories whose bluebooks are copies, fixtures or other checkouts, not the repository's own.
      SKIPPED = %r{(\A|/)(\.claude|\.git|node_modules|tmp|vendor|fixtures)/}

      # The end of a bluebook's file name, which a `.behaviors` file replaces.
      BLUEBOOK_SUFFIX = /\.bluebook\z/

      # @param registry [Runtime::Registry, nil] unused
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the checkout to count when the ask names none
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
      end

      # The `Count` ask.
      #
      # @param held [Hash] the `BehaviorsCoverage` record: `run` and an optional `root`
      # @return [Hash{Symbol => Hash}] `report`, `missing` and `total`, as value objects
      def count(**held)
        root = plain(held[:root]) || @root
        names = bluebooks(root)
        lacking = names.reject { |name| File.exist?(name.sub(BLUEBOOK_SUFFIX, ".behaviors")) }
        answer(lacking.map { |name| name.delete_prefix("#{root}/") }, names.size)
      end

      private

      def bluebooks(root)
        Dir.glob(File.join(root, "**", "*.bluebook")).reject { |name| name.delete_prefix(root).match?(SKIPPED) }.sort
      end

      def answer(lacking, total)
        report = lacking.empty? ? "every bluebook has a .behaviors file" : lacking.join("\n")
        { report: { value: report }, missing: { value: lacking.size }, total: { value: total } }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
