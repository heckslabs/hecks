module Hecks
  # The one place that freezes a domain value all the way down, not just its container.
  # Instance state and command arguments are deliberately left unfrozen; values and events are.
  module Freezer
    module_function

    # Freezes a Hash, Array or String and everything inside it.
    #
    # @param held [Object] any domain value
    # @return [Object] `held`, recursively frozen if it is a Hash, Array, or
    #   String; returned unchanged otherwise
    def deep(held)
      case held
      when Hash   then held.each_value { |inner| deep(inner) }.freeze
      when Array  then held.each { |inner| deep(inner) }.freeze
      when String then held.freeze
      else held
      end
    end

    # True when `held` and everything reachable from it is frozen.
    #
    # @param held [Object] any domain value
    # @return [Boolean] true if `held` and everything reachable from it is frozen
    def deeply_frozen?(held) = unfrozen_within(held).nil?

    # The path to the first mutable thing reachable from `held`, or nil.
    #
    # @param held [Object] any domain value
    # @param path [Array<String>] the owner path accumulated by the recursive
    #   walk so far; callers pass nothing and get the default
    # @return [String, nil] the dotted path (Hash keys, Array indices, or
    #   `"(the value itself)"`) to the first mutable value found, or nil if none
    def unfrozen_within(held, path = [])
      return (path.empty? ? "(the value itself)" : path.join(".")) unless immune?(held) || held.frozen?

      case held
      when Hash  then held.lazy.filter_map { |key, inner| unfrozen_within(inner, path + [key.to_s]) }.first
      when Array then held.each_with_index.lazy.filter_map { |inner, i| unfrozen_within(inner, path + [i.to_s]) }.first
      end
    end

    # Explicit rather than trusting `frozen?` on immediates.
    #
    # @param held [Object] any domain value
    # @return [Boolean] true if `held` is nil, true, false, a Numeric, or a Symbol
    def immune?(held) = held.nil? || held == true || held == false || held.is_a?(Numeric) || held.is_a?(Symbol)
  end
end
