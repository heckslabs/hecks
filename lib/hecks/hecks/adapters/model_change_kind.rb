# frozen_string_literal: true

module Hecks
  module Adapters
    # The kind of a change to a bluebook's storage shape, read from the change the mint already
    # computes (`PostgresEra::LineageManager::LedgerChange`: anything answering `added`, `widened`
    # and `replaced`), so a review and the mint judge a shape move alike.
    #
    # It sees storage shape only. A new command, policy or event leaves the shape alone and reads as
    # `:no_shape_change`, which is not a comment-only change: a source that covers the whole IR is
    # needed to tell those apart.
    module ModelChangeKind
      # What a change can be, from the lightest to the heaviest.
      KINDS = %i[no_shape_change additive breaking].freeze

      # @param change [#added, #widened, #replaced] the shape change between two bluebooks
      # @return [Symbol] `:breaking` when any aggregate was replaced (that wins over a mixed
      #   change), `:additive` when aggregates were only added or widened, else `:no_shape_change`
      def self.of(change)
        return :breaking unless change.replaced.empty?

        change.added.empty? && change.widened.empty? ? :no_shape_change : :additive
      end
    end
  end
end
