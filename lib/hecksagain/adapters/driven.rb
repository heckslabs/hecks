module Hecksagain
  module Adapters
    # The driven side — every store or reader an adapter declaration can
    # bind. A small adapter is one file beside this one; sqlite, postgres
    # and heki keep a directory for their supporting cast. Each `.adapter`
    # file alongside is the DSL declaration the grammar bootstrap and the
    # Folder adapter load as data.
  end
end

require_relative "driven/memory"
require_relative "driven/sqlite/sqlite"
require_relative "driven/postgres/postgres"
require_relative "driven/heki"
require_relative "driven/prism"
require_relative "driven/folder"
