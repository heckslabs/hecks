# Dev tools concern — development-time web capabilities
require_relative "dsl"

Hecks.concern :dev_tools do
  includes :tailwind, :acceptance_test, :web_client_state, :web_debug
end
