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
    #   key => :command | :query | :port_operation   the kind of verb that key must name
    #
    # A `:port_operation` verb is spelled `"Aggregate.Port.Operation"` and names
    # an operation the chapter's hecksagon declares on one of its aggregates.
    # The hecksagon attaches after the chapter is built, so the chapter itself
    # only checks the spelling; `Registry#verify!` checks the operation exists.
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
      # Sending an issue to the confirmed subscribers: the decision to send
      # and the record of each email handed to the mail provider. A separate
      # capability from `NEWSLETTER` so a chapter that only takes signups
      # declares nothing more; rust/host serves the send route only when a
      # chapter declares this one as well.
      NEWSLETTER_ISSUES = "newsletter_issues".freeze

      # Taking a payment through an external processor: start one, then
      # hear the processor's verdict — recognised by declaration, not the
      # literal chapter name "Payments". rust/host's checkout and webhook
      # routes dispatch these verbs and read the paying aggregate's
      # instances off `initiate`. The two verdicts are hecksagon port
      # operations (the processor's webhook, translated into this chapter's
      # vocabulary), not commands.
      PAYMENTS = "payments".freeze

      # Scheduling sessions and taking registrations for them — recognised
      # by declaration, not the literal aggregate names "Event" and
      # "Registration". rust/host's event and registration routes dispatch
      # these verbs; the aggregates they name are the event and the
      # registration.
      REGISTRATIONS = "registrations".freeze

      # A business's connection to its payment processor: connect it, drop
      # it, pause it, and switch taking payments on or off — recognised by
      # declaration, not the literal name "PaymentConnection". rust/host's
      # payments routes dispatch these verbs; the connection aggregate is
      # the one `connect` names.
      PAYMENT_CONNECTION = "payment_connection".freeze

      CONTRACTS = {
        AUTHORIZATION      => {
          # every assignment an actor holds, current or historical
          assignments: :query,
          # the command that grants an actor a role
          grant:       :command,
          # every grant of one role acting as another
          transitions: :query
        }.freeze,
        MEMBERSHIP         => {
          # recognize a person who may eventually sign in
          admit:  :command,
          # grant an admitted person a role (the access-grant half)
          grant:  :command,
          # every admitted person, for the admin listing
          people: :query
        }.freeze,
        IDENTITY           => {
          # mint a stable identity, independent of how it authenticated
          register: :command,
          # associate an (issuer, subject) pair with that identity
          link:     :command,
          # look up the identity an authenticated pair resolves to
          resolve:  :query
        }.freeze,
        NEWSLETTER         => {
          # a guest signs up; the aggregate it names is the subscriber
          subscribe:   :command,
          # attach a display name to an existing subscriber
          add_name:    :command,
          # a subscriber confirms their address from the emailed link
          confirm:     :command,
          # a subscriber leaves from the emailed link
          unsubscribe: :command
        }.freeze,
        NEWSLETTER_ISSUES  => {
          # mark an issue sent; the issue aggregate is the one it names
          send_issue:      :command,
          # record one email handed to the mail provider; the delivery
          # aggregate is the one it names
          record_delivery: :command
        }.freeze,
        PAYMENTS           => {
          # start a payment; the aggregate it names is the payment
          initiate:  :command,
          # the processor reports the money arrived
          succeeded: :port_operation,
          # the processor reports the payment failed or expired
          failed:    :port_operation
        }.freeze,
        REGISTRATIONS      => {
          # schedule a session; the aggregate it names is the event
          schedule: :command,
          # a guest asks for a place; the aggregate it names is the registration
          request:  :command
        }.freeze,
        PAYMENT_CONNECTION => {
          # link the processor account; the aggregate it names is the connection
          connect:    :command,
          # link a different processor account after a disconnect
          reconnect:  :command,
          # drop the link
          disconnect: :command,
          # pause the connection without dropping it
          suspend:    :command,
          # lift a pause
          resume:     :command,
          # switch taking payments on
          enable:     :command,
          # switch taking payments off
          disable:    :command
        }.freeze
      }.freeze
    end
  end
end
