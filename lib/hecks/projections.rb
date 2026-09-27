require_relative "projector"

module Hecks
  # Targets a domain can be projected into, as constants — `Pizzas.project(Projections::OIDC)`
  # — so a typo raises `NameError` here instead of `UnknownProjector` at dispatch time.
  module Projections
  end
end

require_relative "projections/ir"
require_relative "projections/shape"
require_relative "projections/oidc"
require_relative "projections/vocabulary"
require_relative "projections/parser_table"
require_relative "projections/bootstrap_table"
require_relative "projections/rust_vocabulary"
require_relative "projections/reference"
require_relative "projections/model"
require_relative "projections/diagrams"
require_relative "projections/statements"
require_relative "projections/glossary"
require_relative "projections/deploy/shared"
require_relative "projections/deploy/lambda"
require_relative "projections/deploy/fargate"
require_relative "projections/deploy/smoke"
require_relative "projections/deploy/template_diff"
