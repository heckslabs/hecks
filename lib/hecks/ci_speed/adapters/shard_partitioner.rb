# frozen_string_literal: true

require "fileutils"
require "json"
require "hecks/tools/shard_planner"

module Hecks
  module Adapters
    # The `Planner` port's adapter: splits a family's files among its shards with the shared
    # longest-processing-time planner and writes the plan where the shard legs read it:
    # `group-<n>.txt` (one file per line), `runtimes.log` (every file's price, for the leg's own
    # worker split) and `plan.json`.
    class ShardPartitioner
      # @param aggregate [Object, nil] unused
      # @param root [String, nil] the checkout patterns are read in; the working directory if nil
      def initialize(aggregate: nil, root: nil)
        @root = root || Dir.pwd
      end

      # @param held [Hash] the `ShardPlan` record and the ask's arguments: `shards`, `items_from`,
      #   `out_dir`, `source` (`timings` or `size`) and `timings`
      # @return [Hash] `shards:`, `files:` and the predicted `longest` and `mean` leg price
      # @raise [ArgumentError] when there is nothing to split
      def partition(**held)
        plan = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
        items = items_of(plan.fetch(:items_from))
        raise ArgumentError, "no files to split in #{plan[:items_from]}" if items.empty?

        prices = prices_of(items, plan)
        groups = Tools::ShardPlanner.partition(items, plan.fetch(:shards), prices)
        write(plan.fetch(:out_dir), groups, prices, plan.fetch(:source))
        answer(groups, prices)
      end

      private

      def items_of(from)
        kind, spec = from.split(":", 2)
        found = kind == "glob" ? Dir.glob(spec, base: @root) : File.readlines(File.join(@root, spec), chomp: true)
        named = found.map(&:strip).reject(&:empty?)
        named.uniq.sort
      end

      def prices_of(items, plan)
        table = plan[:source] == "timings" ? Tools::ShardPlanner.parse(plan[:timings]) : {}
        Tools::ShardPlanner.prices(items, table, ->(item) { File.size?(File.join(@root, item)) || 1 })
      end

      def write(dir, groups, prices, source)
        out = File.join(@root, dir)
        FileUtils.mkdir_p(out)
        groups.each_with_index { |files, index| File.write(File.join(out, "group-#{index + 1}.txt"), listing(files)) }
        File.write(File.join(out, "runtimes.log"), listing(prices.map { |file, price| "#{file}:#{price}" }.sort))
        File.write(File.join(out, "plan.json"), JSON.pretty_generate(source: source, groups: groups))
      end

      def listing(lines) = lines.empty? ? "" : "#{lines.join("\n")}\n"

      def answer(groups, prices)
        loads = groups.map { |files| files.sum { |file| prices.fetch(file) } }
        { shards: { value: groups.size }, files: { value: prices.size },
          longest: { value: loads.max.round(2) }, mean: { value: (loads.sum / loads.size).round(2) } }
      end
    end
  end
end
