require_relative "projector"

module Hecks
  # THE TARGETS A DOMAIN CAN BE PROJECTED INTO, as constants rather than
  # bare symbols — `Pizzas.project(Projections::OIDC)`.
  #
  # A constant is worth the namespace for two reasons a Symbol cannot
  # give: a typo raises `NameError` at the call site instead of
  # `UnknownProjector` at dispatch time, and each target has somewhere to
  # carry its own documentation and defaults.
  #
  # Namespaced rather than top-level because `IR` is already taken —
  # `Hecks::Bluebook` is the MODEL (`Bluebook::Command`, and the
  # chapter class itself).
  # `Projections::IR` is the projection OF that model, a different thing
  # that would be genuinely confusing under the same bare name.
  #
  # `include Hecks::Projections` gets the short spelling where the
  # extra qualification is noise (`bin/` scripts, a console session).
  module Projections
  end
end

require_relative "projections/ir"
require_relative "projections/shape"
require_relative "projections/oidc"
require_relative "projections/vocabulary"
require_relative "projections/parser_table"
require_relative "projections/reference"
require_relative "projections/model"
