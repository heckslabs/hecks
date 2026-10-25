module Hecks
  module Runtime
    # The answer to "would this command be accepted?": every reason it would not be, as data.
    #
    # Advisory. A passing validation does not promise the real dispatch will pass, since the state
    # it read can change in between; the dispatch stays authoritative.
    class Validation
      # @return [Array<Hecks::Refused>] the refusals, in the order dispatch would have found them
      attr_reader :refusals

      # @param refusals [Array<Hecks::Refused>] what refused; one the facts gate and the
      #   interpreter's gate both found is kept once
      def initialize(refusals)
        @refusals = refusals.uniq { |refusal| [refusal.class, refusal.path, refusal.rule, refusal.message] }.freeze
      end

      # @return [Boolean] whether nothing refused
      def ok? = refusals.empty?

      # @return [Hash{Symbol => Object}] `ok` and each refusal as plain data
      def to_h = { ok: ok?, refusals: refusals.map(&:to_h) }
    end
  end
end
