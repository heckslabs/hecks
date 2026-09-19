module Hecks
  module Forms
    # A Field tree (field_shape.rb) -> `{path => [[id, label], ...]}` for
    # every `:reference` field in it — the options a `<select>` needs.
    # Shared by CommandFormRenderer and QueryFormRenderer alike: a
    # command's own reference field and a query's own reference parameter
    # resolve against the same repository the same way, and neither word
    # owns this more than the other.
    module ReferenceOptions
      # Collects every `:reference` field's own dropdown options out of a resolved field
      # tree.
      #
      # @param registry [Runtime::Registry] the booted registry to read repositories from
      # @param domain [String] the owning chapter's name
      # @param fields [Array<Forms::Field>] the resolved field tree to search
      # @return [Hash{String => Array<Array(String, String)>, nil}] one entry per
      #   `:reference` field found, keyed by its `path`; `nil` when the field's target
      #   could not be resolved or its options could not be read
      def self.collect(registry, domain, fields)
        targets = {}
        walk(fields) { |field| targets[field.path] = field.target_aggregate if field.kind == :reference }
        targets.transform_values { |aggregate| aggregate && options_for(registry, domain, aggregate) }
      end

      # Visits every field in a tree, depth-first, including each `:list`/`:group`
      # field's own children.
      #
      # @param fields [Array<Forms::Field>] the field tree to walk
      # @yieldparam field [Forms::Field] each field visited, parent before children
      # @return [void]
      def self.walk(fields, &block)
        fields.each do |field|
          block.call(field)
          walk(field.children, &block) if field.children
        end
      end

      # Reads up to 200 records' ids as `<select>` options, for one reference field's
      # target aggregate.
      #
      # @param registry [Runtime::Registry] the booted registry to read the repository from
      # @param domain [String] the owning chapter's name
      # @param aggregate [Bluebook::Aggregate] the referenced aggregate to list
      # @return [Array<Array(String, String)>, nil] up to 200 `[id, id]` pairs; `nil` when
      #   the repository cannot be resolved (a wiring gap degrades to a plain text id
      #   input, not a 500)
      def self.options_for(registry, domain, aggregate)
        registry.repository(domain, aggregate).all.first(200).map { |instance| [instance.id, instance.id] }
      rescue StandardError
        nil # a wiring gap (no repository bound) degrades to a plain text id input, not a 500
      end
    end
  end
end
