module Hecksagain
  module Bluebook
    module IR
      class Policy

        # The BLUEBOOK's name for this construct, asked the same way of a class
        # that has crossed over and of an IR object that has not. Collapses into
        # Construct when this one crosses.
        def hecks_name = @name
        attr_reader :name, :on_event, :trigger_command, :target_domain

        def initialize(name:, on_event: nil, trigger_command: nil, target_domain: nil)
          @name            = name.to_s
          @on_event        = on_event
          @trigger_command = trigger_command
          @target_domain   = target_domain
        end

        def event_qualifier = Naming.qualifier(@on_event)

        def event_name = Naming.unqualified(@on_event)

        def to_h
          {
            name:            @name,
            on_event:        @on_event,
            trigger_command: @trigger_command,
            target_domain:   @target_domain
          }
        end
      end
    end
  end
end
