require_relative "../adapters/driven/folder"

module Hecks
  module Ports
    # The `loading` port: `bootstrap` hands back the Folder adapter that
    # reads bluebook files off disk to build the very first registry, before
    # any other port has a registry to resolve against.
    module Loading
      NAME = "loading".freeze

      module_function

      def bootstrap = Adapters::Folder.new
    end
  end
end
