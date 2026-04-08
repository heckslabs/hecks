# Observable concern — metrics + audit
require_relative "dsl"

Hecks.concern :observable do
  includes :metrics, :audit
end
