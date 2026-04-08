# Webapp concern — full web app stack
require_relative "dsl"

Hecks.concern :webapp do
  includes :project_discovery, :static_assets, :websocket, :live_reload, :client_commands, :readme
end
