# Hecks::DomainVersioning::BreakingClassifier
#
# Classifies domain diff changes as breaking or non-breaking for
# interface versioning. Extends the structural diff with a label
# indicating whether downstream consumers would break.
#
#   changes = Hecks::Migrations::DomainDiff.call(old_domain, new_domain)
#   classified = BreakingClassifier.classify(changes)
#   classified.each { |c| puts "#{c[:label]} #{c[:breaking] ? 'BREAKING' : ''}" }
#
module Hecks
  module DomainVersioning
    # Hecks::DomainVersioning::BreakingClassifier
    #
    # Classifies domain diff changes as breaking or non-breaking for interface versioning decisions.
    #
    module BreakingClassifier
      BREAKING_KINDS = %i[
        remove_aggregate
        remove_attribute
        remove_command
        remove_value_object
        remove_entity
      ].freeze

      NON_BREAKING_KINDS = %i[
        add_aggregate
        add_attribute
        add_command
        add_value_object
        add_entity
        add_query
        add_scope
        add_specification
        add_policy
        add_subscriber
        add_validation
        add_index
        add_reference
        add_invariant
      ].freeze

      # Classify a list of DomainDiff::Change objects.
      #
      # @param changes [Array<Hecks::Migrations::DomainDiff::Change>]
      # @return [Array<Hash>] each with :change, :label, :breaking keys
      def self.classify(changes)
        changes.map do |change|
          { change: change, label: format_label(change), breaking: breaking?(change) }
        end
      end

      # Is this change kind breaking?
      #
      # @param change [Hecks::Migrations::DomainDiff::Change]
      # @return [Boolean]
      def self.breaking?(change)
        BREAKING_KINDS.include?(change.kind)
      end

      # Format a human-readable label for a change.
      #
      # @param change [Hecks::Migrations::DomainDiff::Change]
      # @return [String]
      def self.format_label(change)
        case change.kind
        when :add_aggregate       then "+ aggregate: #{change.aggregate}"
        when :remove_aggregate    then "- aggregate: #{change.aggregate}"
        when :add_attribute       then "+ attribute: #{change.aggregate}.#{change.details[:name]} (#{change.details[:type]})"
        when :remove_attribute    then "- attribute: #{change.aggregate}.#{change.details[:name]}"
        when :add_command         then "+ command: #{change.aggregate}.#{change.details[:name]}"
        when :remove_command      then "- command: #{change.aggregate}.#{change.details[:name]}"
        when :add_query           then "+ query: #{change.aggregate}.#{change.details[:name]}"
        when :remove_query        then "- query: #{change.aggregate}.#{change.details[:name]}"
        when :add_value_object    then "+ value_object: #{change.aggregate}.#{change.details[:name]}"
        when :remove_value_object then "- value_object: #{change.aggregate}.#{change.details[:name]}"
        when :add_entity          then "+ entity: #{change.aggregate}.#{change.details[:name]}"
        when :remove_entity       then "- entity: #{change.aggregate}.#{change.details[:name]}"
        when :add_policy          then "+ policy: #{change.aggregate}.#{change.details[:name]}"
        when :remove_policy       then "- policy: #{change.aggregate}.#{change.details[:name]}"
        when :add_scope           then "+ scope: #{change.aggregate}.#{change.details[:name]}"
        when :remove_scope        then "- scope: #{change.aggregate}.#{change.details[:name]}"
        when :add_specification   then "+ specification: #{change.aggregate}.#{change.details[:name]}"
        when :remove_specification then "- specification: #{change.aggregate}.#{change.details[:name]}"
        when :add_validation      then "+ validation: #{change.aggregate}.#{change.details[:field]}"
        when :remove_validation   then "- validation: #{change.aggregate}.#{change.details[:field]}"
        when :add_index           then "+ index: #{change.aggregate}"
        when :remove_index        then "- index: #{change.aggregate}"
        when :add_reference       then "+ reference: #{change.aggregate}"
        when :remove_reference    then "- reference: #{change.aggregate}"
        when :change_policy       then "~ policy: #{change.aggregate}.#{change.details[:name]}"
        else "#{change.kind}: #{change.aggregate} #{change.details}"
        end
      end
    end
  end
end
