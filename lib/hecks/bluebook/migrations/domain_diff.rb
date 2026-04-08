Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::MigrationsParagraph,
  base_dir: File.expand_path("domain_diff", __dir__)
)

module Hecks
  module Migrations
    # Hecks::Migrations::BluebookDiff
    #
    # Compares two domain snapshots and produces a list of Change objects
    # describing what was added, removed, or modified. Adapter-agnostic --
    # the changes are structural, not tied to any persistence format.
    #
    # Detects changes in:
    # - Aggregates (add/remove)
    # - Attributes (add/remove on existing aggregates)
    # - Value objects (add/remove)
    # - Entities (add/remove)
    # - Commands, policies, validations, invariants, queries, scopes,
    #   subscribers, specifications (via BehaviorDiff mixin)
    #
    # Used by MigrationStrategies to detect what changed and generate
    # appropriate migration files.
    #
    #   old_domain = Hecks.bluebook("Pizzas") { ... }
    #   new_domain = Hecks.bluebook("Pizzas") { ... }
    #   changes = BluebookDiff.call(old_domain, new_domain)
    #   # => [Change.new(kind: :add_attribute, aggregate: "Pizza", details: {...}), ...]
    #
    class BluebookDiff
    include BehaviorDiff

    # Struct representing a single change between two domain versions.
    #
    # @!attribute kind [Symbol] the type of change (e.g., :add_aggregate,
    #   :remove_attribute, :add_command)
    # @!attribute context [Symbol, nil] :behavior for behavioral changes, nil
    #   for structural changes
    # @!attribute aggregate [String] the name of the affected aggregate
    # @!attribute details [Hash] change-specific data (varies by kind)
    Change = Struct.new(:kind, :context, :aggregate, :details, keyword_init: true)

    # Convenience class method to compute changes between two domains.
    #
    # @param old_domain [Hecks::BluebookModel::Domain, nil] the previous domain version (nil for first build)
    # @param new_domain [Hecks::BluebookModel::Domain] the current domain version
    # @return [Array<Change>] list of detected changes
    def self.call(old_domain, new_domain)
      new(old_domain, new_domain).changes
    end

    # @param old_domain [Hecks::BluebookModel::Domain, nil] the previous domain version
    # @param new_domain [Hecks::BluebookModel::Domain] the current domain version
    def initialize(old_domain, new_domain)
      @old = old_domain
      @new = new_domain
    end

    # Compute all changes between the old and new domain versions. Iterates
    # over new aggregates to find additions and modifications, then checks
    # for removed aggregates.
    #
    # @return [Array<Change>] list of all detected changes
    def changes
      result = []
      old_aggs_by_name = (@old&.aggregates || []).each_with_object({}) { |a, h| h[a.name] = a }

      @new.aggregates.each do |new_agg|
        old_agg = old_aggs_by_name[new_agg.name]

        if old_agg.nil?
          result << Change.new(
            kind: :add_aggregate,
            context: nil,
            aggregate: new_agg.name,
            details: { attributes: new_agg.attributes, references: new_agg.references, value_objects: new_agg.value_objects, validations: new_agg.validations }
          )
        else
          # Structural diffs
          result.concat(diff_attributes(old_agg, new_agg))
          result.concat(diff_references(old_agg, new_agg))
          result.concat(diff_value_objects(old_agg, new_agg))
          result.concat(diff_entities(old_agg, new_agg))
          # Behavioral diffs
          result.concat(diff_commands(old_agg, new_agg))
          result.concat(diff_policies(old_agg, new_agg))
          result.concat(diff_validations(old_agg, new_agg))
          result.concat(diff_invariants(old_agg, new_agg))
          result.concat(diff_queries(old_agg, new_agg))
          result.concat(diff_scopes(old_agg, new_agg))
          result.concat(diff_subscribers(old_agg, new_agg))
          result.concat(diff_specifications(old_agg, new_agg))
        end
      end

      # Removed aggregates
      new_agg_names = @new.aggregates.map(&:name)
      (@old&.aggregates || []).each do |old_agg|
        unless new_agg_names.include?(old_agg.name)
          result << Change.new(
            kind: :remove_aggregate,
            context: nil,
            aggregate: old_agg.name,
            details: {}
          )
        end
      end

      result
    end

    private

    # Diff attributes between old and new versions of the same aggregate.
    # Detects added and removed attributes by name comparison.
    #
    # @param old_agg [Hecks::BluebookModel::Aggregate] the previous aggregate version
    # @param new_agg [Hecks::BluebookModel::Aggregate] the current aggregate version
    # @return [Array<Change>] attribute-level changes
    def diff_attributes(old_agg, new_agg)
      changes = []
      old_names = old_agg.attributes.map(&:name)
      new_names = new_agg.attributes.map(&:name)

      # Added attributes
      (new_names - old_names).each do |name|
        attr = new_agg.attributes.find { |a| a.name == name }
        validation = new_agg.validations.find { |v| v.field == attr.name }
        changes << Change.new(
          kind: :add_attribute,
          context: nil,
          aggregate: new_agg.name,
          details: { name: attr.name, type: attr.type, list: attr.list?,
                     default: attr.default, presence: validation&.presence?, uniqueness: validation&.uniqueness? }
        )
      end

      # Removed attributes
      (old_names - new_names).each do |name|
        changes << Change.new(
          kind: :remove_attribute,
          context: nil,
          aggregate: new_agg.name,
          details: { name: name }
        )
      end

      changes
    end

    # Diff value objects between old and new versions of the same aggregate.
    # Detects added and removed value objects by name comparison.
    #
    # @param old_agg [Hecks::BluebookModel::Aggregate] the previous aggregate version
    # @param new_agg [Hecks::BluebookModel::Aggregate] the current aggregate version
    # @return [Array<Change>] value object-level changes
    def diff_value_objects(old_agg, new_agg)
      changes = []
      old_vo_names = old_agg.value_objects.map(&:name)
      new_vo_names = new_agg.value_objects.map(&:name)

      (new_vo_names - old_vo_names).each do |name|
        vo = new_agg.value_objects.find { |v| v.name == name }
        changes << Change.new(
          kind: :add_value_object,
          context: nil,
          aggregate: new_agg.name,
          details: { name: vo.name, attributes: vo.attributes }
        )
      end

      (old_vo_names - new_vo_names).each do |name|
        changes << Change.new(
          kind: :remove_value_object,
          context: nil,
          aggregate: new_agg.name,
          details: { name: name }
        )
      end

      changes
    end

    # Diff entities between old and new versions of the same aggregate.
    # Detects added and removed entities by name comparison.
    #
    # @param old_agg [Hecks::BluebookModel::Aggregate] the previous aggregate version
    # @param new_agg [Hecks::BluebookModel::Aggregate] the current aggregate version
    # @return [Array<Change>] entity-level changes
    def diff_entities(old_agg, new_agg)
      changes = []
      old_ent_names = (old_agg.entities || []).map(&:name)
      new_ent_names = (new_agg.entities || []).map(&:name)

      (new_ent_names - old_ent_names).each do |name|
        ent = new_agg.entities.find { |e| e.name == name }
        changes << Change.new(
          kind: :add_entity,
          context: nil,
          aggregate: new_agg.name,
          details: { name: ent.name, attributes: ent.attributes }
        )
      end

      (old_ent_names - new_ent_names).each do |name|
        changes << Change.new(
          kind: :remove_entity,
          context: nil,
          aggregate: new_agg.name,
          details: { name: name }
        )
      end

      changes
    end

    # Diff references between old and new versions of the same aggregate.
    #
    # @param old_agg [Hecks::BluebookModel::Aggregate] the previous aggregate version
    # @param new_agg [Hecks::BluebookModel::Aggregate] the current aggregate version
    # @return [Array<Change>] reference-level changes
    def diff_references(old_agg, new_agg)
      changes = []
      old_refs = (old_agg.references || []).map(&:name)
      new_refs = (new_agg.references || []).map(&:name)

      (new_agg.references || []).each do |ref|
        unless old_refs.include?(ref.name)
          changes << Change.new(
            kind: :add_reference,
            context: nil,
            aggregate: new_agg.name,
            details: { reference: ref }
          )
        end
      end

      (old_agg.references || []).each do |ref|
        unless new_refs.include?(ref.name)
          changes << Change.new(
            kind: :remove_reference,
            context: nil,
            aggregate: new_agg.name,
            details: { reference: ref }
          )
        end
      end

      changes
    end


    end
  end
end
