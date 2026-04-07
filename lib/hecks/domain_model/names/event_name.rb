# Hecks::DomainModel::Names::EventName
#
# Value object wrapping an event name string (e.g. "CreatedPizza").
#
#   name = EventName.wrap("CreatedPizza")
#   name == "CreatedPizza"  # => true
#
module Hecks
  module DomainModel
    module Names
      class EventName < BaseName; end
    end
  end
end
