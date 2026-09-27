require_relative "behaviors/dsl"
require_relative "behaviors/expectations"
require_relative "behaviors/runner"

# The `.behaviors` toolkit driven by `bin/behaviors` and `hecks/behaviors/rspec`.
# Opt-in: not required by lib/hecks.rb, like `Fuzzing`.
# lib/hecks/fuzzing.rb, the shape this file mirrors) is opt-in too.
module Hecks
  class << self
    # `Hecks.behaviors "Name" do ... end`. Not routed through `collect`: a behaviors suite is a
    # test artifact, so it stays out of `Runtime.current_registry`.
    #
    # @param name [String] the suite's declared name
    # @yield the suite's body, evaluated against a `Behaviors::BehaviorsBuilder`
    # @return [Behaviors::BehaviorsSuite] the built suite, also stashed as
    #   `Behaviors.last_suite`
    # @raise [Behaviors::LoadOutsideRunner] if called outside `Behaviors.run(path)`
    # @raise [Behaviors::Malformed] if the suite declares no `vision` or `loads`, or
    #   any of its `test` blocks is malformed
    def behaviors(name, &)
      path = Behaviors.loading_path or
        raise Behaviors::LoadOutsideRunner,
              "Hecks.behaviors called outside Hecks::Behaviors.run(path) — " \
              "a .behaviors file is only ever loaded by the behaviors runner"

      Behaviors.last_suite = Behaviors::BehaviorsBuilder.build(name, source_path: path, &)
    end
  end
end
