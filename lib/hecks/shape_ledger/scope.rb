# frozen_string_literal: true

module Hecks
  module ShapeLedger
    # Which bluebooks the ledger holds. A bluebook is held when its committed persistence is an
    # era-managed adapter, or when it is a framework member such as Governance, which clients
    # persist. Every other bluebook is tooling, Memory by its committed world (ADR 0136), with no
    # database whose eras a shape change could strand.
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
        held, skipped = registry.bluebooks.partition { |name, bluebook| held?(registry, name, bluebook) }
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

        "\nskipped #{skipped.size} tooling bluebooks (committed persistence: #{skipped.values.uniq.join(", ")}): " \
          "#{skipped.keys.join(", ")}"
      end

      def held?(registry, name, bluebook)
        Framework.members.key?(name) || Runtime::RevisionCheck.lineage_capable?(registry, adapter_of(registry, name, bluebook))
      end

      def adapter_of(registry, name, bluebook) = Kept.adapter_of(registry, name, bluebook)
    end
  end
end
