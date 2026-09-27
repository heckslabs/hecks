module Hecks
  module Bluebook
    # What a chapter may declare it provides — trusted in place of a literal
    # chapter-name check by role checks, adapters and the fuzzer.
    module Capabilities
      AUTHORIZATION = "authorization".freeze
      # Who may sign in and with what role, resolved by declaration rather
      # than an env var naming the aggregate.
      MEMBERSHIP = "membership".freeze
      # A stable organizational identity, recognised by declaration rather
      # than the literal name "Identity".
      IDENTITY = "identity".freeze
      # Guest newsletter signups, recognised by declaration rather than the
      # literal chapter name "Newsletter".
      NEWSLETTER = "newsletter".freeze
      # Sending an issue to confirmed subscribers; kept separate from
      # NEWSLETTER so a signup-only chapter declares nothing more.
      NEWSLETTER_ISSUES = "newsletter_issues".freeze

      # Taking a payment through an external processor, recognised by
      # declaration rather than the literal name "Payments"; the two
      # verdicts are port operations, not commands.
      PAYMENTS = "payments".freeze

      # Scheduling sessions and taking registrations, recognised by
      # declaration rather than the literal aggregate names.
      REGISTRATIONS = "registrations".freeze

      # A business's connection to its payment processor, recognised by
      # declaration rather than the literal name "PaymentConnection".
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
