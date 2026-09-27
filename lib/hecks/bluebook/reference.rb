module Hecks
  module Bluebook
    # An attribute that points at another aggregate's head.
    #
    # Holds the target name and resolves lazily through the chapter's own IR, since
    # `reference_to` may name an aggregate declared later in the file.
    # `to_s` spells `"Reference<Customer>"`, which the export contract pins.
    class Reference
      attr_reader :target_name

      # The Aggregate whose declaration carries this reference, stamped once siblings are read.
      attr_accessor :declared_in

      # @param target_name [Module, String, Symbol] the aggregate constant this
      #   reference points at, or its already-spelled name
      def initialize(target_name)
        @target_name = Naming.demodulise(target_name).to_s
      end

      # The Aggregate this points at, or nil when the target belongs to another domain.
      #
      # @return [Bluebook::Aggregate, nil] the target aggregate, or `nil` when
      #   `declared_in`'s own chapter does not declare one by this name
      # @raise [DSL::Malformed] if `declared_in` is unset, so there is no
      #   chapter to resolve the target against
      def resolve
        unless declared_in
          raise DSL::Malformed,
                "#{self} cannot say which aggregate declares it, so it cannot " \
                "resolve — a reference that resolves to nothing is checked " \
                "against nothing"
        end

        declared_in.hecks_owner&.aggregate(@target_name)
      end

      # The IR spelling, the one the export carries.
      #
      # @return [String] `"Reference<TargetName>"`
      def to_s = "Reference<#{@target_name}>"
      def inspect = "#<Reference #{@target_name}>"

      # Value equality on the target; `declared_in` is excluded so references parsed from
      # separate reads compare equal (EraGuard's shape diff depends on it).
      #
      # @param other [Object] the value to compare against
      # @return [Boolean] whether `other` is a `Reference` to the same target
      def ==(other) = other.is_a?(Reference) && target_name == other.target_name
      alias eql? ==
      def hash = [self.class, target_name].hash
    end
  end
end
