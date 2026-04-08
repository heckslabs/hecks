# Webstack concern — webapp + REST API + auth
require_relative "dsl"

Hecks.concern :webstack do
  includes :webapp, :http, :auth
end
