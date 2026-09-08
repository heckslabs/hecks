module Hecks
  # Namespace for every driven-side adapter (Memory, Folder, SQLite,
  # Postgres, Heki, ...) a `persisted_by`/port binding can resolve to;
  # concrete adapters are required in below from adapters/driven and
  # register themselves into this namespace as they load.
  module Adapters
  end
end

require_relative "adapters/driven"
