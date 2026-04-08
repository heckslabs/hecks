# API concern — REST API with auth and throttling
require_relative "dsl"

Hecks.concern :api do
  includes :http, :auth, :rate_limit
end
