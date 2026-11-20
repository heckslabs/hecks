module Hecks
  module Ports
    module Persistence
      # When an atomic put may take an occupied id: the occupant's lifecycle has ended. The rule
      # is the lifecycle's own (`Bluebook::Lifecycle#reusable?`): a state marked `:reusable`, or a
      # state the lifecycle never declares. An adapter that judges in SQL reads `field`,
      # `reusable` and `declared` to say the same rule there.
      class ReplaceWhen
        attr_reader :lifecycle

        # The rule for an aggregate's lifecycle, or nil when the lifecycle frees no ids.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate a creating command writes
        # @return [ReplaceWhen, nil] nil for no lifecycle, or one that marks no state `:reusable`
        def self.for(aggregate)
          lifecycle = aggregate.lifecycle
          lifecycle&.marked(:reusable) ? new(lifecycle) : nil
        end

        # @param lifecycle [Bluebook::Lifecycle] a lifecycle that marks states `:reusable`
        def initialize(lifecycle)
          @lifecycle = lifecycle
        end

        # @return [Symbol] the attribute the lifecycle's status lives on
        def field = lifecycle.field

        # @return [Array<String>] the states marked `:reusable`
        def reusable = lifecycle.marked(:reusable)

        # @return [Array<String>] every state the lifecycle declares
        def declared = lifecycle.states

        # Whether an occupant has ended, so a new record may take its id.
        #
        # @param occupant [Runtime::Instance] the record found under the id
        # @return [Boolean] false for an occupant with no status
        def replaces?(occupant) = lifecycle.reusable?(occupant[field])

        # The first free `<id>~<n>`, counting from 1. D1 finds the same id in SQL, with a
        # recursive count over the same candidates, so every adapter archives under one name.
        #
        # @param id [String, Object] the occupied id
        # @yieldparam candidate [String] an archive id to test
        # @yieldreturn [Boolean] whether a record already holds the candidate
        # @return [String] the first candidate no record holds
        def archive_id(id)
          (1..).each do |n|
            candidate = "#{id}~#{n}"
            return candidate unless yield(candidate)
          end
        end
      end
    end
  end
end
