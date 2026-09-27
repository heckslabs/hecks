module Hecks
  module Bluebook
    module Behaviour
      # **What an attribute does**: the questions readers ask about its declared shape.
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

        # May this fact be left out? Required is the default; only a command enforces
        # this, since aggregate and value object attributes are not caller payloads.
        #
        # @return [Boolean] whether a command may omit this attribute from its payload
        def optional? = @optional
      end
    end
  end
end
