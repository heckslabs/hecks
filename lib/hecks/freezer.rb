module Hecks
  # The one place that knows how to freeze a domain value.
  #
  # Freezing here has been fixed four times in four places, each time by
  # topping the container and leaving the contents: list attributes, the
  # event log, query rows, and value objects. `.freeze` on a Hash stops a
  # key being added or removed and nothing else — the String, Array or
  # Hash a field holds stays mutable, so a caller reaches straight
  # through and edits in place. Each fix looked complete and none was.
  #
  # ## What should be frozen, and why it is not everything
  #
  # A value object has no identity to change over. `with` already
  # answers a new one rather than mutating, so freezing it through is
  # what it always claimed to be.
  #
  # An emitted event is a record of something that happened. A mutable
  # audit trail is not one.
  #
  # A query row is an answer, not a handle — mutating one edits nobody's
  # state and silently disagrees with the store.
  #
  # An instance's state is not frozen, deliberately: the interpreter
  # builds it up across a dispatch, and a command's whole job is to
  # change it. Its values are frozen; the holder is not.
  #
  # A command's arguments are not frozen either. They arrive from
  # outside, are normalised and coerced on the way in, and the coerced
  # result is what becomes a frozen value.
  module Freezer
    module_function

    # Freezes `held` and everything reachable inside it.
    #
    # Numbers, symbols, nil and booleans are already immediate or frozen;
    # a Value froze itself when it was built. What is left is the mutable
    # trio, and each has to be walked rather than topped.
    #
    # @param held [Object] value to freeze, recursed into through Hash and Array
    # @return [Object] `held`, frozen (deeply, for Hash, Array and String)
    def deep(held)
      case held
      when Hash   then held.each_value { |inner| deep(inner) }.freeze
      when Array  then held.each { |inner| deep(inner) }.freeze
      when String then held.freeze
      else held
      end
    end

    # Tells whether every value reachable from `held` is frozen.
    #
    # The question a gate asks, rather than the act. Answers false for the
    # first thing that is reachable and mutable, which is what makes a
    # failure message worth reading.
    #
    # @param held [Object] value to check, recursed into through Hash and Array
    # @return [Boolean]
    def deeply_frozen?(held) = unfrozen_within(held).nil?

    # Finds the first mutable value reachable from `held`.
    #
    # A path rather than a boolean because "something in this event is
    # mutable" is not an actionable sentence.
    #
    # @param held [Object] value to search, recursed into through Hash and Array
    # @param path [Array<String>] key/index path accumulated by the recursion so far
    # @return [String, nil] dotted path to the first mutable value found, the literal
    #   `"(the value itself)"` when `held` itself is mutable, or nil when nothing is
    def unfrozen_within(held, path = [])
      return (path.empty? ? "(the value itself)" : path.join(".")) unless immune?(held) || held.frozen?

      case held
      when Hash  then held.lazy.filter_map { |key, inner| unfrozen_within(inner, path + [key.to_s]) }.first
      when Array then held.each_with_index.lazy.filter_map { |inner, i| unfrozen_within(inner, path + [i.to_s]) }.first
      end
    end

    # Tells whether `held` is one of the types Ruby always treats as immutable.
    #
    # Immediates are frozen in every Ruby that matters, but asking
    # `frozen?` of them and trusting the answer has bitten enough people
    # that it is worth being explicit.
    #
    # @param held [Object] value to check
    # @return [Boolean]
    def immune?(held) = held.nil? || held == true || held == false || held.is_a?(Numeric) || held.is_a?(Symbol)
  end
end
