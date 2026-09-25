module Hecks
  module Bluebook
    # What a chapter may declare it provides, and what each capability
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
      # Who may sign in, and with what role — rust/host's Google-OAuth
      # provision/member_rows resolve this instead of an env var naming
      # the aggregate (HECKS_MEMBERSHIP_AGGREGATE). Same declared-
      # not-named shape AUTHORIZATION already is for Governance.
      MEMBERSHIP = "membership".freeze
      # A stable organizational identity, independent of how it was
      # authenticated — recognised by declaration, not the literal name
      # "Identity". Same declared-not-named shape AUTHORIZATION already
      # is. rust/host does not build this chapter's payloads; any field
      # mapping lives on the consuming hecksagon's `translates` ACL.
      IDENTITY = "identity".freeze
      # Guest-facing newsletter signup: who subscribed, confirmed, or left —
      # recognised by declaration, not the literal chapter name
      # "Newsletter". rust/host's newsletter routes dispatch these verbs
      # and read the subscribing aggregate's instances off `subscribe`.
      NEWSLETTER = "newsletter".freeze

      CONTRACTS = {
        AUTHORIZATION => {
          # every assignment an actor holds, current or historical
          assignments: :query,
          # the command that grants an actor a role
          grant:       :command,
          # every grant of one role acting as another
          transitions: :query
        }.freeze,
        MEMBERSHIP    => {
          # recognize a person who may eventually sign in
          admit:  :command,
          # grant an admitted person a role (the access-grant half)
          grant:  :command,
          # every admitted person, for the admin listing
          people: :query
        }.freeze,
        IDENTITY      => {
          # mint a stable identity, independent of how it authenticated
          register: :command,
          # associate an (issuer, subject) pair with that identity
          link:     :command,
          # look up the identity an authenticated pair resolves to
          resolve:  :query
        }.freeze,
        NEWSLETTER    => {
          # a guest signs up; the aggregate it names is the subscriber
          subscribe:   :command,
          # attach a display name to an existing subscriber
          add_name:    :command,
          # a subscriber confirms their address from the emailed link
          confirm:     :command,
          # a subscriber leaves from the emailed link
          unsubscribe: :command
        }.freeze
      }.freeze
    end
  end
end
