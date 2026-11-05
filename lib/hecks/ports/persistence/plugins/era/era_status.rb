require_relative "era_check"
require_relative "storage_shape"

module Hecks
  module Runtime
    # What a boot would resolve for each bluebook a registry loaded, asked of the same adapter the
    # boot's era gate asks (`RevisionCheck`), against the database each bluebook's own world
    # declares.
    # Nothing is minted, provisioned or recorded: an era-holding adapter answers over a connection
    # that can only read. A bluebook bound to an adapter that holds no eras answers `no_eras`.
    module RevisionStatus
      module_function

      # @param registry [Runtime::Registry] the loaded registry, as a boot loads it
      # @param directory [String] the domain's bluebook directory
      # @return [Hash{String => Hash}] each bluebook's status row, by name: `status`, `held`,
      #   `current`, `ordinal`, `move`, `reason` and `source` (`database`, or `none` for `no_eras`)
      # @raise [Runtime::WiringError] if a binding cannot be resolved, a database is unreachable, or
      #   a held text was altered
      def rows(registry, directory)
        registry.bluebooks.to_h { |name, bluebook| [name, row_for(registry, bluebook, directory)] }
      end

      # One bluebook's status row.
      #
      # @param registry [Runtime::Registry] the loaded registry
      # @param bluebook [Bluebook::Declaration] the bluebook as it stands
      # @param directory [String] the domain's bluebook directory
      # @return [Hash] the row
      def row_for(registry, bluebook, directory)
        first = bluebook.aggregates.first
        adapter = first && RevisionCheck.adapter_for(registry, bluebook.name, first)
        layout = adapter && RevisionCheck.revision_adapter(registry, bluebook.name, adapter)
        return no_eras(bluebook, adapter || "nothing") unless layout && RevisionCheck.lineage_capable?(registry, layout)

        settings = registry.binding_settings(bluebook.name, Ports::Persistence::VERB, adapter)
        registry.adapter_class(layout).era_status(registry: registry, bluebook: bluebook, settings: settings,
                                                  directory: directory).to_row
      end

      # @param bluebook [Bluebook::Declaration] the bluebook
      # @param adapter [String] the adapter it is bound to
      # @return [Hash] the row of a bluebook whose store holds no eras
      def no_eras(bluebook, adapter)
        { "status" => "no_eras", "held" => nil, "current" => StorageShape.mint_label(bluebook), "ordinal" => nil,
          "move" => nil, "reason" => "#{bluebook.name} is bound to #{adapter}, which holds no eras", "source" => "none" }
      end
    end
  end
end
