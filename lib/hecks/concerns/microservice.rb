# Microservice concern — production-ready service
require_relative "dsl"

Hecks.concern :microservice do
  includes :http, :auth, :metrics, :rate_limit
end
