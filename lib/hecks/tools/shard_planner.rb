# frozen_string_literal: true

module Hecks
  module Tools
    # The longest-processing-time split every sharded CI family shares: spec files of the rspec and
    # postgres io jobs, and the domains of a fuzz sweep. It is a pure function of the items, the
    # shard count and the prices, so the same input gives the same partition.
    #
    # A price is a recorded run time when the table holds one for the item, the table's median when
    # it holds others but not this one, and the item's size when there is no table at all.
    module ShardPlanner
      # One `key:seconds` line; seconds can arrive in exponent form (`9.69e-05`). Anything else,
      # such as RSpec's "Run options" line, is not a timing.
      LINE = /\A(?<key>\S+):(?<seconds>\d+(?:\.\d+)?(?:e-?\d+)?)\z/

      module_function

      # @param text [String] lines of `key:seconds`
      # @return [Hash{String => Float}] the seconds of each key; a malformed line is skipped
      def parse(text)
        lines = text.to_s.lines.map(&:strip)
        timed = lines.filter_map { |line| LINE.match(line) }
        timed.to_h { |match| [match[:key], Float(match[:seconds])] }
      end

      # @param texts [Array<String>] several shards' timing logs
      # @return [Hash{String => Float}] one table; a key in two logs keeps the later seconds
      def merge(texts) = texts.reduce({}) { |table, text| table.merge(parse(text)) }

      # @param items [Array<String>] what is to be split
      # @param table [Hash{String => Float}] recorded seconds, perhaps empty or lacking some items
      # @param sizes [#call] answers an item's size in bytes, used only when the table is empty
      # @return [Hash{String => Float}] each item's price
      def prices(items, table, sizes)
        return items.to_h { |item| [item, sizes.call(item).to_f] } if table.empty?

        fallback = median(table.values)
        items.to_h { |item| [item, table.fetch(item, fallback)] }
      end

      # @param items [Array<String>] what is to be split, each unique
      # @param groups [Integer] how many groups to deal into
      # @param prices [Hash{String => Float}] each item's price
      # @return [Array<Array<String>>] the items of each group, dearest first, each to the lightest
      #   group so far, the lowest numbered when they tie
      def partition(items, groups, prices)
        loads = Array.new(groups, 0.0)
        dealt = Array.new(groups) { [] }
        items.sort_by { |item| [-prices.fetch(item), item] }.each do |item|
          lightest = loads.each_index.min_by { |group| [loads[group], group] }
          loads[lightest] += prices.fetch(item)
          dealt[lightest] << item
        end
        dealt
      end

      # @param values [Array<Float>] at least one
      # @return [Float] the middle value
      def median(values)
        ranked = values.sort
        (ranked[(ranked.size - 1) / 2] + ranked[ranked.size / 2]) / 2.0
      end
    end
  end
end
