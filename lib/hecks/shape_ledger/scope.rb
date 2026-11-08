# frozen_string_literal: true

module Hecks
  module ShapeLedger
    # Which bluebooks the ledger holds: those `Kept` says are kept (ADR 0190). The scope keeps no
    # rule of its own. Every other bluebook is disposable, with no data whose eras a shape change
    # could strand.
    module Scope
      module_function

      # @param directory [String] the domain directory
      # @return [Runtime::Registry] its bluebooks as committed: no local or environment overlay
      def committed_registry(directory)
        Adapters::FolderOverlay.committed_only { Hecks.describe(directory, environment: nil).registry }
      end

      # @param registry [Runtime::Registry] the committed registry
      # @return [Array(Array<String>, Hash{String => String})] the names the ledger holds, and each
      #   skipped bluebook's name mapped to its committed adapter
      def of(registry)
        held, skipped = registry.bluebooks.partition { |name, bluebook| Kept.of?(registry, name, bluebook) }
        [held.map(&:first), skipped.to_h { |name, bluebook| [name, adapter_of(registry, name, bluebook)] }]
      end

      # @return [Array(Hash, Hash, Hash)] the shapes and the ledger entries of the bluebooks held,
      #   and the bluebooks skipped
      def view(registry, path)
        skipped = of(registry).last
        [ShapeLedger.shapes_of(registry), ShapeLedger.read(path)].map { |held| held.except(*skipped.keys) } << skipped
      end

      # @return [String] the line naming the skipped bluebooks, empty when there are none
      def note(skipped)
        return "" if skipped.empty?

        "\nskipped #{skipped.size} disposable bluebooks (committed persistence: #{skipped.values.uniq.join(", ")}): " \
          "#{skipped.keys.join(", ")}"
      end

      def adapter_of(registry, name, bluebook) = Kept.adapter_of(registry, name, bluebook)
    end
  end
end
