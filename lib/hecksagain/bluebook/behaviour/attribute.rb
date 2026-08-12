module Hecksagain
  class Bluebook
    module Behaviour
      # WHAT AN ATTRIBUTE DOES. The declared half — name, type, list,
      # default, optional, pattern, admits — is what the language states
      # in `aggregate.bluebook`'s own `Field`. These are the questions
      # readers ask ABOUT that shape, which no declaration states.
      module Attribute
        def list?      = @list
        def scalar?    = !@list
        def reference? = @type.is_a?(Reference)

        # MAY THIS FACT BE LEFT OUT?
        #
        # Required is the default and by far the common case — a command takes
        # the arguments it declares, and all of them — so the EXCEPTION is what
        # gets marked. Marking the other way would annotate almost every
        # attribute in the corpus to say nothing.
        #
        # Only a COMMAND enforces this. An aggregate's own attributes are filled
        # by the commands that set them, and a value object's by its
        # constructor ; neither is a payload anyone hands in.
        def optional? = @optional
      end
    end
  end
end
