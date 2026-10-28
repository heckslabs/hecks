module Hecks
  module Bluebook
    # The findings a declaration may acknowledge, and the rule an acknowledgement must meet: a
    # reason, and a kind the check really emits (ADR 0150).
    module Acknowledgements
      # The finding kinds an aggregate may acknowledge.
      AGGREGATE_KINDS = %i[large_aggregate].freeze

      # The finding kinds a context-map relationship may acknowledge: those about the relationship
      # itself. An undeclared coupling or a separate-ways breach has no relationship to carry the
      # allowance; the fix is to declare one.
      RELATIONSHIP_KINDS = %i[relationship_kind_mismatch conformist_translates unpublished_dependency
                              unused_relationship].freeze

      # @param owner [String] the declaration carrying the word, for the message
      # @param finding [Symbol, String] the kind being acknowledged
      # @param reason [Object] why; must be non-blank text
      # @param among [Array<Symbol>] the kinds the owner may acknowledge
      # @return [Symbol] the kind, once it passes
      # @raise [DSL::Malformed] if the kind is not among those, or the reason is blank
      def self.kind!(owner, finding, reason, among: AGGREGATE_KINDS)
        kind = finding.to_s.to_sym
        refuse_kind!(owner, kind, among) unless among.include?(kind)
        refuse_reason!(owner, kind) unless reason.is_a?(String) && !reason.strip.empty?
        kind
      end

      # @raise [DSL::Malformed] always, naming the kinds that can be acknowledged
      def self.refuse_kind!(owner, kind, among)
        raise DSL::Malformed,
              "#{owner} acknowledges :#{kind}, a finding model_check does not report here — " \
              "the kinds are #{among.map(&:inspect).join(", ")}"
      end

      # @raise [DSL::Malformed] always, saying a reason is required
      def self.refuse_reason!(owner, kind)
        raise DSL::Malformed,
              "#{owner} acknowledges :#{kind} without a reason in text — an allowance says why it is allowed"
      end

      # @param aggregate [Bluebook::Aggregate] the aggregate to read
      # @param kind [Symbol] a finding kind
      # @return [Boolean] whether the aggregate acknowledges that kind
      def self.held?(aggregate, kind)
        aggregate.acknowledgements.any? { |held| held.finding.to_sym == kind }
      end
    end
  end
end
