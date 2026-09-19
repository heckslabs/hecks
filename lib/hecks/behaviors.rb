require_relative "behaviors/dsl"
require_relative "behaviors/expectations"
require_relative "behaviors/runner"

# The `.behaviors` toolkit `bin/behaviors` and a consumer's own rspec shim
# (`hecks/behaviors/rspec`) drive. Not required by lib/hecks.rb on
# purpose — a booted domain never needs it, the same reason `Fuzzing` (see
# lib/hecks/fuzzing.rb, the shape this file mirrors) is opt-in too.
module Hecks
  class << self
    # Declares one `.behaviors` file's suite and stashes it where the runner that loaded
    # the file can pick it up.
    #
    # `Hecks.behaviors "Name" do ... end` — deliberately not routed
    # through `collect` the way `bluebook`/`hecksagon`/`world` are: a
    # behaviors suite is a test artifact a runner reads on demand, never
    # a thing a live domain boot needs, so it has no business landing in
    # `Runtime.current_registry`.
    #
    # @param name [String] the suite's name, as passed to `Hecks.behaviors`
    # @yield the block declaring `vision`, `loads` and each `test`, evaluated against a
    #   `Behaviors::BehaviorsBuilder`
    # @return [void]
    # @raise [Behaviors::LoadOutsideRunner] if called other than while `Behaviors.run`
    #   is loading a `.behaviors` file
    # @raise [Behaviors::Malformed] if the block declares no `vision` or no `loads`
    def behaviors(name, &)
      path = Behaviors.loading_path or
        raise Behaviors::LoadOutsideRunner,
              "Hecks.behaviors called outside Hecks::Behaviors.run(path) — " \
              "a .behaviors file is only ever loaded by the behaviors runner"

      Behaviors.last_suite = Behaviors::BehaviorsBuilder.build(name, source_path: path, &)
    end
  end
end
