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
      # `NEWSLETTER` so a signup-only chapter declares nothing more.
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

      # The checkout boundary in front of a payment processor: how long a
      # signed webhook stays fresh and how long a session holds its seat,
      # recognised by declaration rather than the literal chapter name.
      CHECKOUT = "checkout".freeze

      # The kinds of contract entry a capability may name: `:command` and
      # `:query` ("Aggregate.Name"), `:port_operation` ("Aggregate.Port.Operation")
      # and `:mark` ("Aggregate.mark_name", the states of that aggregate's
      # lifecycle mark) and `:duration` ("Aggregate.attribute", the whole-seconds
      # `default:` of that attribute, ADR 0098). `:mark` and `:duration` entries are
      # optional; every other entry is required.
      #
      # ADR 0099 adds two more optional kinds: `:text` ("Aggregate.attribute", the string
      # `default:` of that attribute, a word the domain owns) and `:attribute`
      # ("Aggregate.attribute", the attribute's own name, for the host to read a field by).
      OPTIONAL_KINDS = %i[mark duration text attribute].freeze

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
          subscribe:             :command,
          # attach a display name to an existing subscriber
          add_name:              :command,
          # a subscriber confirms their address from the emailed link
          confirm:               :command,
          # a subscriber leaves from the emailed link
          unsubscribe:           :command,
          # Optional: the subscriber states that await the emailed confirm
          # link, spelled "Subscriber.awaiting_confirmation"
          awaiting_confirmation: :mark,
          # Optional: the subscriber states that receive each issue sent
          receives_issues:       :mark,
          # Optional: the subscriber states of someone who has left
          left:                  :mark,
          # Optional: how many seconds the emailed confirm link stays valid,
          # spelled "Subscriber.confirm_window"
          confirm_window:        :duration,
          # Optional: how many seconds an emailed unsubscribe link stays valid
          unsubscribe_window:    :duration
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
          initiate:     :command,
          # the processor reports the money arrived
          succeeded:    :port_operation,
          # the processor reports the payment failed or expired
          failed:       :port_operation,
          # Optional: the lifecycle states of the payment that hold a seat,
          # spelled "Payment.holds_seat" (Aggregate.mark_name); resolves to the
          # states of that aggregate's lifecycle `mark :holds_seat`
          holds_seat:   :mark,
          # Optional: the failure reason a lapsed checkout hold records, spelled
          # "Payment.lapse_reason" (the string `default:` of that attribute)
          lapse_reason: :text
        }.freeze,
        REGISTRATIONS      => {
          # schedule a session; the aggregate it names is the event
          schedule:      :command,
          # a guest asks for a place; the aggregate it names is the registration
          request:       :command,
          # Optional: the registration attribute that stamps when it was asked for,
          # spelled "Registration.requested_at"
          registered_at: :attribute
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
        }.freeze,
        CHECKOUT           => {
          # Optional: how many seconds either side of now a signed webhook's
          # timestamp may sit, spelled "WebhookReceipt.tolerance"
          webhook_tolerance: :duration,
          # Optional: how many seconds a session holds its seat
          session_hold:      :duration
        }.freeze
      }.freeze

      # The whole seconds a duration attribute's `default:` holds: a bare integer, or the
      # `{ value: N }` fill of a one-field value object (how a bluebook types a number).
      #
      # @param default [Object] an attribute's `default:`
      # @return [Integer, nil] the positive whole seconds, or `nil` when it is not that
      def self.duration_seconds(default)
        seconds = filled_value(default)
        seconds if seconds.is_a?(Integer) && seconds.positive?
      end

      # The seconds a `:duration` verb ("Aggregate.attribute") resolves to in `chapter`.
      #
      # @param chapter [Bluebook::Chapter] the chapter that declares the aggregate
      # @param verb [String] the entry, spelled "Aggregate.attribute"
      # @return [Integer, nil] the positive whole seconds, or `nil` when the verb names no such
      #   attribute or its default is not whole seconds
      def self.duration_of(chapter, verb)
        duration_seconds(attribute_default(chapter, verb))
      end

      # The `default:` of the attribute a verb ("Aggregate.attribute") names in `chapter`.
      #
      # @param chapter [Bluebook::Chapter] the chapter that declares the aggregate
      # @param verb [String] the entry, spelled "Aggregate.attribute"
      # @return [Object, nil] that attribute's `default:`, or `nil` when there is none
      def self.attribute_default(chapter, verb)
        aggregate_name, attribute_name = verb.split(".", 2)
        chapter.aggregate(aggregate_name)&.attributes&.find { |a| a.name.to_s == attribute_name }&.default
      end

      # A default's value: the bare value, or the `{ value: x }` fill of a one-field value object.
      #
      # @param default [Object] an attribute's `default:`
      # @return [Object] the bare value
      def self.filled_value(default)
        default.is_a?(Hash) ? default.fetch(:value) { default["value"] } : default
      end

      # The string a `:text` verb ("Aggregate.attribute") resolves to in `chapter`: the attribute's
      # `default:`, bare or as the `{ value: "..." }` fill of a one-field value object (ADR 0099).
      #
      # @param chapter [Bluebook::Chapter] the chapter that declares the aggregate
      # @param verb [String] the entry, spelled "Aggregate.attribute"
      # @return [String, nil] the non-empty text, or `nil` when the verb names no such attribute
      #   or its default is not text
      def self.text_of(chapter, verb)
        text = filled_value(attribute_default(chapter, verb))
        text if text.is_a?(String) && !text.empty?
      end

      # The attribute name an `:attribute` verb ("Aggregate.attribute") resolves to in `chapter`.
      #
      # @param chapter [Bluebook::Chapter] the chapter that declares the aggregate
      # @param verb [String] the entry, spelled "Aggregate.attribute"
      # @return [String, nil] the attribute's name, or `nil` when the aggregate lacks it
      def self.attribute_of(chapter, verb)
        aggregate_name, attribute_name = verb.split(".", 2)
        found = chapter.aggregate(aggregate_name)&.attributes&.any? { |a| a.name.to_s == attribute_name }
        attribute_name if found
      end

      # The keys a capability's `provides` must name.
      #
      # @param capability [String] a `CONTRACTS` key
      # @return [Array<Symbol>] the keys whose kind is not optional
      def self.required_keys(capability)
        CONTRACTS.fetch(capability).reject { |_, kind| OPTIONAL_KINDS.include?(kind) }.keys
      end
    end
  end
end
