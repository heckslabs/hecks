module Hecks
  module Bluebook
    module Behaviour
      # **What an attribute does**. The declared half — name, type, list,
      # default, optional, pattern, admits — is what the language states
      # in `aggregate.bluebook`'s own `Field`. These are the questions
      # readers ask about that shape, which no declaration states.
      module Attribute
        # Says whether this attribute was declared `list`.
        #
        # @return [Boolean] whether this attribute holds a list of values rather than one
        def list?      = @list

        # Says whether this attribute holds a single value rather than a list.
        #
        # @return [Boolean] whether this attribute holds a single value rather than a list
        def scalar?    = !@list

        # Says whether this attribute's type is another aggregate reached via `reference_to`.
        #
        # @return [Boolean] whether this attribute's type is a `reference_to` another aggregate
        def reference? = @type.is_a?(Reference)

        # May this fact be left out?
        #
        # Required is the default and by far the common case — a command takes
        # the arguments it declares, and all of them — so the exception is what
        # gets marked. Marking the other way would annotate almost every
        # attribute in the corpus to say nothing.
        #
        # Only a command enforces this. An aggregate's own attributes are filled
        # by the commands that set them, and a value object's by its
        # constructor ; neither is a payload anyone hands in.
        #
        # @return [Boolean] whether a command may omit this attribute from its payload
        def optional? = @optional
      end
    end
  end
end
