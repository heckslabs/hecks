module Hecksagain
  module Bluebook
    module Behaviour
      # WHAT A POLICY DOES. Its declared half is four plain fields; these
      # are the readings taken off them.
      module Policy
        # The BLUEBOOK's name for this construct, asked the same way of a class
        # that has crossed over and of an IR object that has not. Collapses into
        # Construct when this one crosses.
        def hecks_name = @name

        def event_qualifier = Naming.qualifier(@on_event)

        def event_name = Naming.unqualified(@on_event)
      end
    end
  end
end
