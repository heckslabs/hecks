require_relative "../projector"

module Hecks
  # The projection targets, each registered under a name; this file adds the `:ir` target.
  module Projections
    # The canonical IR projection, registered as `:ir`.
    # Aliases `Projector::IRProjector` rather than reimplementing it, so IR has one renderer.
    IR = Projector::IRProjector

    IR.extend(Projector::Target)
    IR.projects_as :ir, requires: Hecks::IR
  end
end
