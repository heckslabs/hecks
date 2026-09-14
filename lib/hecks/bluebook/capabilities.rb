module Hecks
  module Bluebook
    # WHAT A CHAPTER MAY DECLARE IT PROVIDES, and what each capability
    # must name. A chapter that `provides "authorization"` is trusted in
    # place of a check for the literal name "Governance" — by the role
    # check at dispatch, the ungoverned-role refusal at boot, the
    # authorization adapter and the fuzzer — so the declaration has to be
    # complete and point at real verbs. `BluebookBuilder::Validation
    # #validate_provisions!` holds every `provides` to this table.
    #
    #   key => :command | :query   the kind of verb that key must name
    module Capabilities
      AUTHORIZATION = "authorization".freeze

      CONTRACTS = {
        AUTHORIZATION => {
          # every assignment an actor holds, current or historical
          assignments: :query,
          # the command that grants an actor a role
          grant:       :command,
          # every grant of one role acting as another
          transitions: :query
        }.freeze
      }.freeze
    end
  end
end
