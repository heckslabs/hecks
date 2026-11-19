module Hecks
  module Bluebook
    # Where the declarations being read come from, when it is a gitignored local file: `:lent`
    # for another checkout's local files, loaded by a worktree that keeps none of its own, and
    # `:local` for this checkout's own. A bind read inside is marked with it, so the wiring gate
    # can leave out one whose aggregate the bluebook does not declare instead of refusing to open.
    module Lent
      KEY = :hecks_lent_declarations

      # The marks a read may carry: another checkout's local files, or this checkout's own.
      PROVENANCES = %i[lent local].freeze

      module_function

      # Runs a block with every bind it reads marked with where it came from.
      #
      # @param lent [Boolean, Symbol] `true` or `:lent` for another checkout's local files,
      #   `:local` for this checkout's own, `false` or nil for committed files
      # @return [Object] the block's value
      def during(lent)
        held = Thread.current[KEY]
        Thread.current[KEY] = lent == true ? :lent : lent
        yield
      ensure
        Thread.current[KEY] = held
      end

      # @return [Boolean] whether the declarations being read now are lent
      def now? = Thread.current[KEY] == :lent

      # @return [Symbol, nil] `:lent`, `:local`, or nil when the declarations are committed
      def provenance = PROVENANCES.include?(Thread.current[KEY]) ? Thread.current[KEY] : nil
    end
  end
end
