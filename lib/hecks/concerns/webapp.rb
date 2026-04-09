# Webapp concern — full web app stack + dev tools
require_relative "dsl"

Hecks.concern :webapp do
  includes :project_discovery, :static_assets, :websocket, :live_reload,
           :client_commands, :readme, :tailwind, :acceptance_test,
           :web_client_state, :web_debug
end
