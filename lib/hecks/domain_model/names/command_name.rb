# Hecks::DomainModel::Names::CommandName
#
# Value object wrapping a command name string (e.g. "CreatePizza").
#
#   name = CommandName.wrap("CreatePizza")
#   name == "CreatePizza"  # => true
#
module Hecks
  module DomainModel
    module Names
      class CommandName < BaseName; end
    end
  end
end
