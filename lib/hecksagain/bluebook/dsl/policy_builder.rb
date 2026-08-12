module Hecksagain
  module Bluebook
    module DSL
      class PolicyBuilder
        def initialize(name)
          @name = name
        end

        def on(event_name) = @on_event = event_name.to_s

        def trigger(command_name) = @trigger_command = command_name.to_s

        def across(domain_name) = @target_domain = domain_name.to_s

        def build
          Policy.new(
            name:            @name,
            on_event:        @on_event,
            trigger_command: @trigger_command,
            target_domain:   @target_domain
          )
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
