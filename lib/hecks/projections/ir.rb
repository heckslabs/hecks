require_relative "../projector"

module Hecks
  # Reopened from projections.rb (see there for the namespace's full
  # rationale) to define and register the :ir target below.
  module Projections
    # The canonical IR, as a constant. The implementation already existed
    # and is already golden-tested (`Projector::IRProjector`, registered
    # as `:ir`) — this only gives it the constant spelling every other
    # target has, by re-registering the SAME module under the same key.
    #
    # Deliberately not a new implementation: two things named `IR` that
    # each rendered IR their own way is exactly the drift this namespace
    # exists to avoid.
    IR = Projector::IRProjector

    IR.extend(Projector::Target)
    IR.projects_as :ir, requires: Hecks::IR
  end
end
