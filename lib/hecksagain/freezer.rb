module Hecksagain
  # THE ONE PLACE THAT KNOWS HOW TO FREEZE A DOMAIN VALUE.
  #
  # Freezing here has been fixed four times in four places, each time by
  # topping the container and leaving the contents: list attributes, the
  # event log, query rows, and value objects. `.freeze` on a Hash stops a
  # key being added or removed and NOTHING ELSE — the String, Array or
  # Hash a field holds stays mutable, so a caller reaches straight
  # through and edits in place. Each fix looked complete and none was.
  #
  # WHAT SHOULD BE FROZEN, and why it is not everything:
  #
  #   A VALUE OBJECT has no identity to change over. `with` already
  #   answers a new one rather than mutating, so freezing it through is
  #   what it always claimed to be.
  #
  #   AN EMITTED EVENT is a record of something that happened. A mutable
  #   audit trail is not one.
  #
  #   A QUERY ROW is an answer, not a handle — mutating one edits nobody's
  #   state and silently disagrees with the store.
  #
  #   AN INSTANCE'S STATE is NOT frozen, deliberately: the interpreter
  #   builds it up across a dispatch, and a command's whole job is to
  #   change it. Its VALUES are frozen; the holder is not.
  #
  #   A COMMAND'S ARGUMENTS are not frozen either. They arrive from
  #   outside, are normalised and coerced on the way in, and the coerced
  #   result is what becomes a frozen value.
  module Freezer
    module_function

    # Numbers, symbols, nil and booleans are already immediate or frozen;
    # a Value froze itself when it was built. What is left is the mutable
    # trio, and each has to be WALKED rather than topped.
    def deep(held)
      case held
      when Hash   then held.each_value { |inner| deep(inner) }.freeze
      when Array  then held.each { |inner| deep(inner) }.freeze
      when String then held.freeze
      else held
      end
    end

    # The question a gate asks, rather than the act. Answers false for the
    # FIRST thing that is reachable and mutable, which is what makes a
    # failure message worth reading.
    def deeply_frozen?(held) = unfrozen_within(held).nil?

    # The path to the first mutable thing reachable from `held`, or nil.
    # A path rather than a boolean because "something in this event is
    # mutable" is not an actionable sentence.
    def unfrozen_within(held, path = [])
      return (path.empty? ? "(the value itself)" : path.join(".")) unless immune?(held) || held.frozen?

      case held
      when Hash  then held.lazy.filter_map { |key, inner| unfrozen_within(inner, path + [key.to_s]) }.first
      when Array then held.each_with_index.lazy.filter_map { |inner, i| unfrozen_within(inner, path + [i.to_s]) }.first
      end
    end

    # Immediates are frozen in every Ruby that matters, but asking
    # `frozen?` of them and trusting the answer has bitten enough people
    # that it is worth being explicit.
    def immune?(held) = held.nil? || held == true || held == false || held.is_a?(Numeric) || held.is_a?(Symbol)
  end
end
