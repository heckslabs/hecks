require_relative "../vocabulary"

module Hecks
  module Runtime
    # Gathers refusals instead of raising the first, for the length of a block.
    #
    # A rule that refuses calls `Collecting.refuse`. With no collector bound it raises, exactly as
    # a plain `raise` would, so dispatch and `dry_run?` behave as they always have. With one bound
    # (by `Dispatcher#validate`) it records the refusal and returns, so a rule that loops over many
    # checks reports every one that fails.
    #
    # The collector is bound per thread, like the caller, so concurrent requests never share one.
    module Collecting
      KEY = :hecks_collector
      STAGE_KEY = :hecks_collecting_stage

      # Which stage each dispatch step belongs to, by step name.
      STAGES = Hecks::Vocabulary.rows("StepStage").to_h { |row| [row["step"].to_sym, row["stage"].to_sym] }.freeze

      module_function

      # Binds a collector for the block.
      #
      # @yield the work whose refusals are gathered
      # @return [Array<Hecks::Refused>] the refusals recorded, in the order they were found
      def collect
        previous = Thread.current[KEY]
        Thread.current[KEY] = collected = []
        yield
        collected
      ensure
        Thread.current[KEY] = previous
      end

      # @return [Boolean] whether a collector is bound on this thread
      def active? = !Thread.current[KEY].nil?

      # @return [Array<Hecks::Refused>, nil] the refusals recorded so far, or nil when none is bound
      def refusals = Thread.current[KEY]

      # Names the stage of the step running for the block, so a refusal recorded in it is placed
      # where it was found, whatever its class would otherwise say (a closed set that refuses a
      # value while an argument is built is an invariant by class and an argument by place).
      #
      # @param stage [Symbol] a `DispatchStage`
      # @yield the step
      # @return [Object] the block's result
      def at_stage(stage)
        previous = Thread.current[STAGE_KEY]
        Thread.current[STAGE_KEY] = stage
        yield
      ensure
        Thread.current[STAGE_KEY] = previous
      end

      # Records a refusal when collecting, raises it otherwise.
      #
      # @param refusal [Hecks::Refused] what refused
      # @return [nil] when collecting
      # @raise [Hecks::Refused] `refusal`, when no collector is bound
      def refuse(refusal)
        raise refusal unless active?

        stage = Thread.current[STAGE_KEY]
        refusals << (stage ? refusal.in_stage(stage) : refusal)
        nil
      end

      # Refuses a set of offenders. Plainly that is one refusal naming them all; when collecting it
      # is one refusal each, so every offender can be shown against its own field.
      #
      # @param names [Array<Symbol>] the offenders
      # @yieldparam group [Array<Symbol>] the offenders one refusal is about
      # @yieldreturn [Hecks::Refused] the refusal for that group
      # @return [void]
      def refuse_each(names)
        groups = active? ? names.zip : [names]
        groups.each { |group| refuse(yield(group)) }
      end

      # @param step [Symbol] a dispatch step name
      # @return [Symbol] the stage it belongs to
      def stage_of(step) = STAGES.fetch(step)
    end
  end
end
