require_relative "keyword_fields"

module Hecks
  module Bluebook
    # One field crossing a value-object boundary, or carried under a new name.
    # Paths are dotted ("price.cents") for a VO member, bare otherwise.
    TranslationMove = Struct.new(:from, :to)

    # One field whose value changed, bridged by an exhaustive lookup table.
    # Paths follow `TranslationMove`; `values` maps each old-era value to its new-era one.
    # `:values` shadows Struct#values on purpose; no caller reads the built-in.
    # rubocop:disable-next Lint/StructNewOverride
    TranslationConvert = Struct.new(:from, :to, :values)

    # A value object's or entity's type name changed with its members unchanged.
    # The attribute kept its name, so `rename`/`move` cannot express it.
    TranslationRetype = Struct.new(:from, :to)

    # A computed transform whose only implementation is a SQL expression run inside
    # the compiled Postgres head; an aggregate carrying one refuses to boot elsewhere.
    TranslationCompute = Struct.new(:from, :to, :sql)

    # The aggregate's own key is recomputed by a SQL expression; stored state is untouched.
    # Postgres-only like `compute`, and it has no `from:`/`to:` path.
    TranslationRekey = Struct.new(:sql)

    # A newly added, required attribute with no source in old data.
    # `default` is what an existing record reads until a command writes a real value;
    # applied in-process by `Lineage#translate` on every adapter.
    TranslationBackfill = Struct.new(:name, :default)

    # One aggregate's part of a translation between eras.
    # `drops` makes data loss a declared decision.
    class TranslationAggregate
      attr_reader :name, :was, :renames, :moves, :converts, :drops, :retypes, :computes, :rekeys, :backfills

      # Every optional field and what it holds when the declaration omits it.
      FIELD_DEFAULTS = {
        was: nil, renames: {}, moves: [], converts: [], drops: [], retypes: [],
        computes: [], rekeys: [], backfills: []
      }.freeze

      # @param name [String, Symbol] the aggregate's name in the destination era
      # @param was [String, Symbol, nil] its name in the origin era, or `nil` if unchanged
      # @param renames [Hash{Symbol => Symbol}] old field name to new field name
      # @param moves [Array<Bluebook::TranslationMove>] fields crossing a value-object boundary
      # @param converts [Array<Bluebook::TranslationConvert>] fields remapped via a lookup table
      # @param drops [Array<Symbol>] fields deliberately not carried forward
      # @param retypes [Array<Bluebook::TranslationRetype>] value object or entity type changes
      # @param computes [Array<Bluebook::TranslationCompute>] fields computed by Postgres-only SQL
      # @param rekeys [Array<Bluebook::TranslationRekey>] SQL recomputing the aggregate's identity
      # @param backfills [Array<Bluebook::TranslationBackfill>] new required fields, no old source
      def initialize(name:, **given)
        KeywordFields.assign(self, KeywordFields.fill(given, FIELD_DEFAULTS))
        @name = name.to_s
        @was  = @was&.to_s
      end
    end

    # A declared map from one era of a domain's storage shape to the next.
    # Old records are translated on replay, never rewritten; `retired` names aggregates removed.
    class Translation
      attr_reader :domain, :from, :to, :aggregates, :retired

      # @param domain [String, Symbol] the domain this translation carries forward
      # @param from [String, Symbol] the origin era
      # @param to [String, Symbol] the destination era
      # @param aggregates [Array<Bluebook::TranslationAggregate>] each aggregate's own
      #   translation rules
      # @param retired [Array<String>] the names of aggregates gone outright in the
      #   destination era
      def initialize(domain:, from:, to:, aggregates: [], retired: [])
        @domain     = domain.to_s
        @from       = from
        @to         = to
        @aggregates = aggregates
        @retired    = retired
      end

      # Finds one aggregate's own translation rules by its destination-era name.
      #
      # @param name [String, Symbol] the aggregate's name in the destination era
      # @return [Bluebook::TranslationAggregate, nil] the aggregate's translation, or
      #   `nil` if `name` carries no translation rules
      def for_aggregate(name) = @aggregates.find { |aggregate| aggregate.name == name.to_s }
    end
  end
end
