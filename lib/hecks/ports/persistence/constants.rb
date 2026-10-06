module Hecks
  module Ports
    # The persistence port's identifying names, loaded before the files that read them.
    module Persistence
      NAME = "persistence".freeze
      VERB = "persisted_by".freeze
      DEFAULT_ADAPTER = "Memory".freeze
    end
  end
end
