# frozen_string_literal: true

require_relative "../literal"

module Hecks
  module RustBuild
    # Makes an appended element's field `Option<T>` in the IR when any command sources it from an
    # optional argument, since Ruby stores the omitted nil without complaint. `ir.json` records
    # the marking, so it runs before the IR is written or generated from.
    #
    # `rust/build/src/optional_pass.rs` is the Ruby-free build's port of this; it looks only at an
    # aggregate's own value objects, where this reads the domain-wide set.
    module AppendOptionals
      # Marks every aggregate in the IR, in place.
      #
      # @param tree [Hash] a domain's IR, symbol-keyed
      # @return [Hash] the same IR
      def self.mark(tree)
        domain_wide = by_name(tree[:aggregates].flat_map { |aggregate| aggregate[:value_objects] })
        tree[:aggregates].each do |aggregate|
          mark_aggregate(aggregate, domain_wide.merge(by_name(aggregate[:value_objects])))
        end
        tree
      end

      # Resolves an `append` target to its entity or value object, or nil if it is neither. A
      # local entity wins over a domain-wide value object of the same name: Syntax's local
      # `Argument` entity shares a name with Command's `Argument` value object.
      #
      # @param aggregate [Hash] the aggregate owning the command
      # @param target_type [String] the appended-to attribute's element type
      # @param value_objects_by_name [Hash{String => Hash}] the value objects in scope
      # @return [Hash, nil] the element, or nil
      def self.element(aggregate, target_type, value_objects_by_name)
        aggregate[:entities].find { |entity| entity[:name] == target_type } ||
          value_objects_by_name[target_type]
      end

      # @param aggregate [Hash] one aggregate of the IR
      # @param value_objects_by_name [Hash{String => Hash}] the value objects in scope
      # @return [void]
      def self.mark_aggregate(aggregate, value_objects_by_name)
        aggregate[:attributes].each do |target_attr|
          target = element(aggregate, target_attr[:type], value_objects_by_name)
          next unless target

          aggregate[:commands].each do |command|
            appends = command[:mutations].select { |m| append_to?(m, target_attr) }
            appends.each { |mutation| mark_fields(mutation, command, target) }
          end
        end
      end

      def self.append_to?(mutation, target_attr)
        mutation[:op].to_s == "append" && mutation[:target].to_s == target_attr[:name].to_s
      end
      private_class_method :append_to?

      # A Symbol is an argument name, and an optional one is what this pass wants; anything
      # else is a literal.
      def self.mark_fields(mutation, command, target)
        mutation[:fields].each do |field_name, source|
          parsed = Hecks::Literal.read(source)
          next unless parsed.is_a?(Symbol)

          source_attr = command[:attributes].find { |attr| attr[:name].to_s == parsed.to_s }
          next unless source_attr && source_attr[:optional]

          field_attr = target[:attributes].find { |attr| attr[:name].to_s == field_name.to_s }
          field_attr[:optional] = true if field_attr
        end
      end
      private_class_method :mark_fields

      def self.by_name(value_objects)
        value_objects.to_h { |value_object| [value_object[:name], value_object] }
      end
      private_class_method :by_name
    end
  end
end
