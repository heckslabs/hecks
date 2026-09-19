require_relative "../adapters/driven/folder"

module Hecks
  module Ports
    # The `loading` port: `bootstrap` hands back the Folder adapter that
    # reads bluebook files off disk to build the very first registry, before
    # any other port has a registry to resolve against.
    module Loading
      NAME = "loading".freeze

      module_function

      # Builds the loader a boot starts from, before any registry exists to resolve one.
      #
      # @return [Adapters::Folder] a new `Folder` adapter with no settings and no root,
      #   constructed directly rather than resolved through a registry
      def bootstrap = Adapters::Folder.new
    end
  end
end
