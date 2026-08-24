require_relative "../adapters/driven/folder"

module Hecks
  module Ports
    module Loading
      NAME = "loading"

      module_function

      def bootstrap = Adapters::Folder.new
    end
  end
end
