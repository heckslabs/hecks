module Hecks
  module Bluebook
    # A translation as data: each aggregate's rules as an ordered list of ops any runtime can
    # interpret, with nothing in them that names a storage engine. In the order they apply to a
    # record, each op has its name under "op" plus:
    #
    #   derive "to" "expression" (a tree)   rename "from" "to"   move "from" "to" (dotted paths)
    #   convert "from" "to" "values" ([old, new] pairs)   drop "path"   retype "from" "to"
    #   backfill "path" "default"   rekey_to "to"
    module TranslationPlan
      VERSION = 1

      # The op names, in the order they apply; one per rule list of a `TranslationAggregate`.
      OPS = %w[derive rename move convert drop retype backfill rekey_to].freeze

      module_function

      # @param translation [Bluebook::Translation] a declared translation edge
      # @return [Hash] the edge as plain data, ready for `JSON.generate`
      def build(translation)
        {
          "version" => VERSION, "domain" => translation.domain, "from" => translation.from.to_s,
          "to" => translation.to.to_s, "retired" => translation.retired.map(&:to_s),
          "aggregates" => translation.aggregates.map { |aggregate| aggregate_plan(aggregate) }
        }
      end

      def aggregate_plan(aggregate)
        { "name" => aggregate.name, "was" => aggregate.was, "ops" => ops(aggregate) }
      end

      def ops(aggregate)
        [*derives(aggregate), *renames(aggregate), *moves(aggregate), *converts(aggregate), *drops(aggregate),
         *retypes(aggregate), *backfills(aggregate), *rekeys(aggregate)]
      end

      def derives(aggregate)
        aggregate.derives.map { |d| { "op" => "derive", "to" => d.to, "expression" => d.tree } }
      end

      def renames(aggregate)
        aggregate.renames.map { |from, to| { "op" => "rename", "from" => from.to_s, "to" => to.to_s } }
      end

      def moves(aggregate)
        aggregate.moves.map { |m| { "op" => "move", "from" => m.from, "to" => m.to } }
      end

      def converts(aggregate)
        aggregate.converts.map do |c|
          { "op" => "convert", "from" => c.from, "to" => c.to, "values" => c.values.map { |old, new| [old, new] } }
        end
      end

      def drops(aggregate) = aggregate.drops.map { |path| { "op" => "drop", "path" => path.to_s } }

      def retypes(aggregate)
        aggregate.retypes.map { |r| { "op" => "retype", "from" => r.from, "to" => r.to } }
      end

      def backfills(aggregate)
        aggregate.backfills.map { |b| { "op" => "backfill", "path" => b.name.to_s, "default" => b.default } }
      end

      def rekeys(aggregate)
        aggregate.rekeys.map { |rekey| { "op" => "rekey_to", "to" => rekey.to } }
      end
    end
  end
end
