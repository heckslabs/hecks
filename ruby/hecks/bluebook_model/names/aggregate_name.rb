# Hecks::BluebookModel::Names::AggregateName
#
# Value object wrapping an aggregate name string (e.g. "Pizza").
#
#   name = AggregateName.wrap("Pizza")
#   name == "Pizza"  # => true
#
module Hecks
  module BluebookModel
    module Names
      class AggregateName < BaseName; end
    end
  end
end
