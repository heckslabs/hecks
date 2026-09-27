module Hecks
  module Bluebook
    # Translates the language's declarations into the IR that `Build` and
    # `Reconstruction` produce; `CONTRACTS` (contracts.rb) holds one per category.
    class Assembly
      # A derived claim's kind is one of :parent, :children, [:computed, method],
      # [:folded, keys], or :elsewhere — each checked structurally, not just named.
      Contract = Struct.new(:holder, :make, :fields, :derived, :rows, :reads, keyword_init: true) do
        # nil means the field reads through the default single-cell reader.
        def reader(key) = Hash(reads)[key.to_sym]

        # nil means the list reads straight off the node.
        def shaper(list) = Hash(rows)[list.to_sym]

        def declares?(field) = fields.key?(field) || derived.key?(field)

        def kind_of(field) = derived[field]

        # Every derived field the walk supplies; Specializer skips these.
        def walked = derived.select { |_field, kind| kind == :walk }.keys

        # [object, member] a folded field lives at; member is nil when the fold
        # has no single one to name (e.g. a count plus a list of rows).
        def folded(field)
          kind = derived[field]
          return nil unless kind.is_a?(Array) && kind.first == :folded

          [kind[1], kind[2]]
        end

        # Computed means the holder answers but its constructor won't accept it —
        # respond_to? alone would also count a stored field like `version`.
        def computes?(method)
          return false unless holder
          return false unless answers?(method)

          !accepts?(method)
        end

        def answers?(method)
          make == :declare ? holder.respond_to?(method) : holder.method_defined?(method)
        end

        def accepts?(keyword)
          builder = make == :declare ? holder.method(:declare) : holder.instance_method(:initialize)

          builder.parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == keyword }
        end
      end

      # Parent-pointer fields that don't end in `_id` (ADR 0025).
      # spec/assembly_spec derives this set independently and fails on drift.
      PARENT_POINTERS = %i[aggregate bluebook owner].freeze

      def self.parent_pointer?(field)
        field.to_s.end_with?("_id") || PARENT_POINTERS.include?(field.to_sym)
      end

      # Fields allowed to describe something other than their own construct.
      # `Bluebook.normalisations` belongs to the expression grammar; `to_h` splices it in.
      ELSEWHERE = {
        Bluebook: %i[normalisations]
      }.freeze

      def self.elsewhere?(category, field)
        Array(ELSEWHERE[category.to_sym]).include?(field)
      end
    end
  end
end
