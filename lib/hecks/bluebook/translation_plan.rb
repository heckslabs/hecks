module Hecks
  module Bluebook
    # A translation as data: each aggregate's rules as an ordered list of ops any runtime can
    # interpret, none naming a storage engine except those marked `requires`. In the order they
    # apply to a record, each op has its name under "op" plus:
    #
    #   derive "to" "expression" (a tree)   rename "from" "to"   move "from" "to" (dotted paths)
    #   convert "from" "to" "values" ([old, new] pairs)   drop "path"   retype "from" "to"
    #   compute "from" "to" "sql" "requires"   backfill "path" "default"   rekey "sql" "requires"
    #   rekey_to "to"
    #
    # `requires` is "postgres" for the ops whose only form is SQL.
    module TranslationPlan
      VERSION = 1

      # The op names, in the order they apply; one per rule list of a `TranslationAggregate`.
      OPS = %w[derive rename move convert drop retype compute backfill rekey rekey_to].freeze

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

      # @param plan [Hash] a plan `build` returned
      # @return [Boolean] true when every op in it can run without a particular storage engine
      def portable?(plan)
        plan["aggregates"].all? { |aggregate| aggregate["ops"].none? { |op| op.key?("requires") } }
      end

      def aggregate_plan(aggregate)
        { "name" => aggregate.name, "was" => aggregate.was, "ops" => ops(aggregate) }
      end

      def ops(aggregate)
        [*derives(aggregate), *renames(aggregate), *moves(aggregate), *converts(aggregate), *drops(aggregate),
         *retypes(aggregate), *computes(aggregate), *backfills(aggregate), *rekeys(aggregate)]
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

      def computes(aggregate)
        aggregate.computes.map do |c|
          { "op" => "compute", "from" => c.from, "to" => c.to, "sql" => c.sql, "requires" => "postgres" }
        end
      end

      def backfills(aggregate)
        aggregate.backfills.map { |b| { "op" => "backfill", "path" => b.name.to_s, "default" => b.default } }
      end

      def rekeys(aggregate)
        aggregate.rekeys.map { |r| r.pure? ? { "op" => "rekey_to", "to" => r.to } : sql_rekey(r) }
      end

      def sql_rekey(rekey)
        { "op" => "rekey", "sql" => rekey.sql, "requires" => "postgres" }
      end
    end
  end
end
