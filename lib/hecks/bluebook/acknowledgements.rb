module Hecks
  module Bluebook
    # The findings a declaration may acknowledge, and the rule an acknowledgement must meet: a
    # reason, and a kind the check really emits (ADR 0150).
    module Acknowledgements
      # The finding kinds an aggregate may acknowledge.
      AGGREGATE_KINDS = %i[large_aggregate key_by_value orphaned_reference].freeze

      # The kinds that are reported once per attribute or per referenced aggregate, so an
      # acknowledgement of one names which (`of:`): the attribute for `key_by_value`, the
      # referenced aggregate for `orphaned_reference`.
      SUBJECT_KINDS = %i[key_by_value orphaned_reference].freeze

      # The finding kinds a context-map relationship may acknowledge: those about the relationship
      # itself. An undeclared coupling or a separate-ways breach has no relationship to carry the
      # allowance; the fix is to declare one.
      RELATIONSHIP_KINDS = %i[relationship_kind_mismatch conformist_translates unpublished_dependency
                              unused_relationship redundant_relationship].freeze

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

      # @param owner [String] the declaration carrying the word, for the message
      # @param kind [Symbol] the kind being acknowledged
      # @param subject [Symbol, String, nil] what `of:` named
      # @return [String, nil] the subject as text, once the kind and subject agree
      # @raise [DSL::Malformed] if a per-subject kind names none, or another kind names one
      def self.subject!(owner, kind, subject)
        named = subject.to_s unless subject.nil? || subject.to_s.strip.empty?
        return named if SUBJECT_KINDS.include?(kind) == !named.nil?

        raise DSL::Malformed, subject_message(owner, kind)
      end

      # @return [String] why the subject and the kind disagree
      def self.subject_message(owner, kind)
        if SUBJECT_KINDS.include?(kind)
          "#{owner} acknowledges :#{kind} without saying which — add `of:` naming the " \
            "#{kind == :key_by_value ? "attribute" : "referenced aggregate"} it is for"
        else
          "#{owner} acknowledges :#{kind} with `of:`, which names a subject only :key_by_value and " \
            ":orphaned_reference have"
        end
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
      # @param subject [Symbol, String, nil] the attribute or referenced aggregate, for the kinds
      #   reported once per subject
      # @return [Boolean] whether the aggregate acknowledges that kind (for that subject)
      def self.held?(aggregate, kind, subject: nil)
        aggregate.acknowledgements.any? do |held|
          held.finding.to_sym == kind && (subject.nil? || held.subject.to_s == subject.to_s)
        end
      end
    end
  end
end
