# Hecks::Ports
#
# The runtime's named boundaries; each port is a file under `ports/`.

module Hecks
  # The runtime's named boundaries; each port is a file under `ports/`.
  module Ports
  end
end

require_relative "ports/loading"
require_relative "ports/persistence"
require_relative "ports/query"
require_relative "ports/projection"
require_relative "ports/extraction"
require_relative "ports/identity_generation"
require_relative "ports/key_vault"
require_relative "ports/authorization"
require_relative "ports/identity_resolution"
require_relative "ports/authentication"
require_relative "ports/access_control"
require_relative "ports/identity_assignment"
require_relative "ports/agent"
require_relative "ports/clock"
