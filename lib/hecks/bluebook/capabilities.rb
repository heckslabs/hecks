require_relative "capabilities/attribute_values"
require_relative "capabilities/package_declared"

module Hecks
  module Bluebook
    # What a bluebook may declare it provides — trusted in place of a literal
    # chapter-name check by role checks, adapters and the fuzzer.
    #
    # The language defines a contract only for the capabilities Hecks itself consumes. Any other
    # `provides` name is the package's own: its keys are checked to name something the bluebook
    # declares (`PackageDeclared`), and whoever reads the capability checks the keys it needs.
    module Capabilities
      extend AttributeValues
      extend PackageDeclared

      AUTHORIZATION = "authorization".freeze
      # Who may sign in and with what role, resolved by declaration rather
      # than an env var naming the aggregate.
      MEMBERSHIP = "membership".freeze
      # A stable organizational identity, recognised by declaration rather
      # than the literal name "Identity".
      IDENTITY = "identity".freeze

      # Marking a domain's attributes sensitive and reading the markings back, recognised by
      # declaration rather than the literal bluebook name "Privacy".
      PRIVACY = "privacy".freeze

      # A subject's key record, shredded to erase them, recognised by declaration rather than the
      # literal names "Privacy" and "SubjectKey".
      SUBJECT_KEYS = "subject_keys".freeze

      # The contract of each capability the language defines: every key a `provides` row must
      # name, and whether it names a command or a query ("Aggregate.Name").
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
        PRIVACY       => {
          # flag one attribute of a domain sensitive
          mark_sensitive: :command,
          # every marking of one domain, for masking a read
          markings_for:   :query
        }.freeze,
        SUBJECT_KEYS  => {
          # the key record of one subject, if any
          key_for: :query,
          # record the subject's key as destroyed
          shred:   :command
        }.freeze
      }.freeze

      # The keys a capability's `provides` must name.
      #
      # @param capability [String] a `CONTRACTS` key
      # @return [Array<Symbol>] every key of its contract
      def self.required_keys(capability) = CONTRACTS.fetch(capability).keys

      # Whether the language defines `capability`'s contract, rather than the package providing it.
      #
      # @param capability [String, Symbol] a capability's name
      # @return [Boolean] whether `CONTRACTS` holds it
      def self.language_defined?(capability) = CONTRACTS.key?(capability.to_s)
    end
  end
end
