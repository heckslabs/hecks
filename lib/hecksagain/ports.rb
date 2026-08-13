# Hecksagain::Ports
#
# The runtime's named boundaries. Each port is a file beside this one —
# `ports/persistence.rb`, `ports/query.rb`, … — and a port with supporting
# cast keeps it in a same-named directory (`ports/persistence/` holds the
# binding policy, the journal-translation lineage, the repository factory).
# The `.port` files beside them are the DSL declarations the meta-validator
# and the Folder adapter load as data.

module Hecksagain
  module Ports
  end
end

require_relative "ports/loading"
require_relative "ports/persistence"
require_relative "ports/query"
require_relative "ports/projection"
require_relative "ports/extraction"
require_relative "ports/identity_generation"
require_relative "ports/authorization"
require_relative "ports/identity_resolution"
require_relative "ports/authentication"
require_relative "ports/access_control"
require_relative "ports/identity_assignment"
require_relative "ports/agent"
require_relative "ports/clock"
