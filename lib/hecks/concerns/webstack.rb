# Webstack concern — webapp + REST API + auth + debug
require_relative "dsl"

Hecks.concern :webstack do
  includes :webapp, :http, :auth, :web_debug
end
