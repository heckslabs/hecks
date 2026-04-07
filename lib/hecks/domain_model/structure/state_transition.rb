# Hecks::DomainModel::Structure::StateTransition
#
# Value object representing a lifecycle state transition. Replaces the
# raw String or Hash previously used in Lifecycle#transitions values.
#
#   t = StateTransition.new(target: "published")
#   t.target  # => "published"
#   t.from    # => nil (any state)
#
#   t = StateTransition.new(target: "published", from: "draft")
#   t.from    # => "draft"
#
module Hecks
  module DomainModel
    module Structure
      class StateTransition
        attr_reader :target, :from

        def initialize(target:, from: nil)
          @target = target.to_s
          @from = case from
                  when Array then from.map(&:to_s)
                  when nil then nil
                  else from.to_s
                  end
        end

        def constrained?
          !@from.nil?
        end

        # Backward compat: transitions were String or Hash
        def to_s = @target
        def to_str = @target

        def ==(other)
          case other
          when StateTransition then @target == other.target && @from == other.from
          when String then @target == other
          when Hash then @target == other[:target].to_s
          else false
          end
        end

        def is_a?(klass)
          return true if klass == String && @from.nil?
          super
        end
      end
    end
  end
end
