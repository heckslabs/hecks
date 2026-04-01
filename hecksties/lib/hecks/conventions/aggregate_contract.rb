# = Hecks::Conventions::AggregateContract
#
# Single source of truth for what every generated aggregate must
# enforce, regardless of target language. Both Ruby and Go generators
# consume this contract to guarantee identical runtime behavior.
#
# Covers: standard fields, validation rules (presence, enum),
# lifecycle defaults + transitions, and invariants.
#
#   rules = Hecks::Conventions::AggregateContract.rules(aggregate_ir)
#   rules[:validations]    # => [{ field: :name, check: :presence }, ...]
#   rules[:enums]          # => [{ field: :category, values: [...] }, ...]
#   rules[:lifecycle]      # => { field: :status, default: "draft", ... }
#   rules[:standard_fields] # => [{ name: :id, type: "string" }, ...]
#
module Hecks::Conventions
  module AggregateContract
    # Every aggregate must have these fields.
    STANDARD_FIELDS = [
      { name: :id,         go: "string",    go_field: "ID",        ruby: "String",  json: "id" },
      { name: :created_at, go: "time.Time", go_field: "CreatedAt", ruby: "Time",    json: "created_at" },
      { name: :updated_at, go: "time.Time", go_field: "UpdatedAt", ruby: "Time",    json: "updated_at" },
    ].freeze

    # Extract all validation rules from an aggregate IR.
    # Returns a hash that both Ruby and Go generators can consume.
    #
    # @param agg [Hecks::DomainModel::Structure::Aggregate]
    # @return [Hash] normalized rules
    def self.rules(agg)
      {
        standard_fields: STANDARD_FIELDS,
        validations: extract_validations(agg),
        enums: extract_enums(agg),
        lifecycle: extract_lifecycle(agg),
        invariants: extract_invariants(agg),
      }
    end

    # Validate that generated code enforces all required rules.
    # Used by smoke tests to verify Ruby and Go output is equivalent.
    #
    # @param agg [Hecks::DomainModel::Structure::Aggregate]
    # @param generated_checks [Array<Hash>] checks found in generated code
    # @return [Hash] { valid:, missing: }
    def self.validate(agg, generated_checks)
      expected = rules(agg)
      missing = []

      expected[:validations].each do |v|
        found = generated_checks.any? { |gc| gc[:field] == v[:field] && gc[:check] == v[:check] }
        missing << "#{v[:check]} on #{v[:field]}" unless found
      end

      expected[:enums].each do |e|
        found = generated_checks.any? { |gc| gc[:field] == e[:field] && gc[:check] == :enum }
        missing << "enum on #{e[:field]}" unless found
      end

      if expected[:lifecycle]
        found = generated_checks.any? { |gc| gc[:check] == :lifecycle_default }
        missing << "lifecycle default" unless found
      end

      { valid: missing.empty?, missing: missing }
    end

    # Compute aggregate name suffixes for self-ref detection.
    # "governance_policy" → ["governance_policy", "policy"]
    #
    # @param agg_snake [String] underscore aggregate name
    # @return [Array<String>] suffixes
    def self.agg_suffixes(agg_snake)
      CommandContract.agg_suffixes(agg_snake)
    end

    # Find the self-referencing reference on a command.
    # e.g., reference_to "GovernancePolicy" on ActivatePolicy command.
    #
    # @param cmd [Command] the command IR
    # @param agg_snake [String] underscore aggregate name
    # @return [Reference, nil] the self-ref reference, or nil for create commands
    def self.self_ref_attr(cmd, agg_snake)
      (cmd.references || []).find do |ref|
        Hecks::Utils.underscore(ref.type) == agg_snake
      end
    end

    # Is this a create command? (no self-ref reference)
    def self.create_command?(cmd, agg_snake)
      self_ref_attr(cmd, agg_snake).nil?
    end

    # Partition commands into create and update groups.
    #
    # @param agg [Aggregate] the aggregate IR
    # @return [Array<Array<Command>>] [create_commands, update_commands]
    def self.partition_commands(agg)
      agg_snake = Hecks::Utils.underscore(agg.name)
      creates = agg.commands.select { |c| create_command?(c, agg_snake) }
      updates = agg.commands - creates
      [creates, updates]
    end

    # For an update command, returns user-visible attributes.
    def self.user_fields(cmd, agg_snake)
      cmd.attributes
    end

    # For an update command, returns non-self references.
    def self.user_refs(cmd, agg_snake)
      self_ref = self_ref_attr(cmd, agg_snake)
      (cmd.references || []).reject { |r| r == self_ref }
    end

    # Is this a direct-action command? (update with no user-visible fields or refs)
    def self.direct_action?(cmd, agg_snake)
      !create_command?(cmd, agg_snake) && user_fields(cmd, agg_snake).empty? && user_refs(cmd, agg_snake).empty?
    end

    class << self
      private

      def extract_validations(agg)
        agg.validations.map do |v|
          checks = []
          checks << { field: v.field, check: :presence } if v.rules[:presence]
          checks << { field: v.field, check: :type, type: v.rules[:type] } if v.rules[:type]
          checks << { field: v.field, check: :uniqueness } if v.rules[:uniqueness]
          checks
        end.flatten
      end

      def extract_enums(agg)
        attrs = agg.attributes.reject { |a|
          Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s)
        }
        attrs.select(&:enum).map do |attr|
          { field: attr.name, values: attr.enum, type: attr.type.to_s }
        end
      end

      def extract_lifecycle(agg)
        return nil unless agg.lifecycle
        lc = agg.lifecycle
        {
          field: lc.field,
          default: lc.default,
          states: lc.states,
          transitions: lc.transitions.map { |cmd_name, target_spec|
            target = target_spec.is_a?(Hash) ? target_spec[:target] : target_spec
            from = target_spec.is_a?(Hash) ? target_spec[:from] : nil
            { command: cmd_name, target: target, from: from }
          },
        }
      end

      def extract_invariants(agg)
        agg.invariants.map do |inv|
          { message: inv.message, has_block: !inv.block.nil? }
        end
      end
    end
  end
end
