# = Hecks::Conventions::MigrationContract
#
# Validates round-trip serialization fidelity for domain snapshots.
# Compares an original domain IR against a restored one to catch
# properties lost during DslSerializer serialize → deserialize.
#
#   result = Hecks::Conventions::MigrationContract.diff(original_domain, restored_domain)
#   result[:valid]   # => true
#   result[:issues]  # => []
#
module Hecks::Conventions
  # Hecks::Conventions::MigrationContract
  #
  # Validates round-trip serialization fidelity by diffing original vs. restored domain IRs.
  #
  module MigrationContract
    # Attribute properties that must survive round-trip serialization.
    ATTRIBUTE_PROPS = %i[name type list?].freeze

    # Aggregate children whose counts must match after round-trip.
    AGGREGATE_CHILDREN = %i[
      attributes value_objects entities commands events
      policies validations invariants scopes queries
      specifications subscribers
    ].freeze

    # Compare two domain IRs and return any differences.
    #
    # @param original [DomainModel::Domain] the domain before serialization
    # @param restored [DomainModel::Domain] the domain after deserialize
    # @return [Hash] { valid: Boolean, issues: Array<String> }
    def self.diff(original, restored)
      issues = []

      original.aggregates.each do |orig_agg|
        rest_agg = restored.aggregates.find { |a| a.name == orig_agg.name }
        unless rest_agg
          issues << "Aggregate #{orig_agg.name} lost in serialization"
          next
        end

        diff_attributes(orig_agg, rest_agg, issues)
        diff_children(orig_agg, rest_agg, issues)
      end

      lost = original.aggregates.map(&:name) - restored.aggregates.map(&:name)
      added = restored.aggregates.map(&:name) - original.aggregates.map(&:name)
      lost.each { |n| issues << "Aggregate #{n} lost" }
      added.each { |n| issues << "Aggregate #{n} appeared unexpectedly" }

      { valid: issues.empty?, issues: issues }
    end

    class << self
      private

      def diff_attributes(orig_agg, rest_agg, issues)
        orig_agg.attributes.each do |attr|
          rest_attr = rest_agg.attributes.find { |a| a.name == attr.name }
          unless rest_attr
            issues << "#{orig_agg.name}.#{attr.name} lost"
            next
          end
          ATTRIBUTE_PROPS.each do |prop|
            orig_val = attr.send(prop)
            rest_val = rest_attr.send(prop)
            next if orig_val == rest_val
            issues << "#{orig_agg.name}.#{attr.name}.#{prop}: #{orig_val.inspect} != #{rest_val.inspect}"
          end
        end
      end

      def diff_children(orig_agg, rest_agg, issues)
        AGGREGATE_CHILDREN.each do |child|
          orig_count = orig_agg.send(child).size
          rest_count = rest_agg.send(child).size
          next if orig_count == rest_count
          issues << "#{orig_agg.name}.#{child}: #{orig_count} -> #{rest_count}"
        end
      end
    end
  end
end
