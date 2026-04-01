module Hecks::Features

  # Hecks::Features::VerticalSlice
  #
  # A vertical slice groups everything triggered by a single entry-point
  # command: the command, its event, any policies it fires, and all
  # downstream commands in the reactive chain.
  #
  #   slice = VerticalSlice.new(
  #     name: "Loan Issuance -> Disbursement",
  #     entry_command: "IssueLoan",
  #     steps: [...],
  #     aggregates: ["Loan", "Account"],
  #     cyclic: false
  #   )
  #   slice.cross_aggregate?  # => true
  #
  class VerticalSlice
    # @return [String] human-readable name derived from the reactive chain
    attr_reader :name

    # @return [String] the command that starts this slice
    attr_reader :entry_command

    # @return [Array<SliceStep>] ordered steps from FlowGenerator trace
    attr_reader :steps

    # @return [Array<String>] unique aggregate names involved in this slice
    attr_reader :aggregates

    # @return [Boolean] whether the slice contains a cycle
    attr_reader :cyclic

    def initialize(name:, entry_command:, steps:, aggregates:, cyclic:)
      @name = name
      @entry_command = entry_command
      @steps = steps
      @aggregates = aggregates
      @cyclic = cyclic
    end

    # Whether this slice spans more than one aggregate.
    #
    # @return [Boolean]
    def cross_aggregate?
      aggregates.size > 1
    end

    # All command names in this slice (entry + downstream).
    #
    # @return [Array<String>]
    def commands
      steps.select { |s| s.type == :command }.map(&:command)
    end

    # All event names emitted in this slice.
    #
    # @return [Array<String>]
    def events
      steps.select { |s| s.type == :command }.map(&:event).compact
    end

    # All policy names in this slice.
    #
    # @return [Array<String>]
    def policies
      steps.select { |s| s.type == :policy }.map(&:policy)
    end

    # Number of steps in the reactive chain.
    #
    # @return [Integer]
    def depth
      steps.size
    end
  end
end
