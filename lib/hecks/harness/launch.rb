# frozen_string_literal: true

require_relative "supervisor"

module Hecks
  module Harness
    # How a session's child is started: the `open` op's `program`, `args`, `model` and `cwd`.
    module Launch
      module_function

      # Each session is the developer's own `claude`, started with the harness's flags.
      #
      # @param model [String, nil] the model to name; Claude Code's own default when nil
      # @param cwd [String, nil] the directory each child starts in
      # @return [Proc] the launch for a session name
      def claude(model: nil, cwd: nil)
        ->(_name) { { program: "claude", model: model, cwd: cwd }.compact }
      end

      # Each session is played from `<dir>/<name>.jsonl`, with no model.
      #
      # @param dir [String] the directory of tapes
      # @param binary [String] the `hecks-harness` binary that plays them
      # @return [Proc] the launch for a session name
      def replay(dir, binary: Supervisor::BINARY)
        ->(name) { { program: binary, args: ["replay", File.join(dir, "#{name}.jsonl")] } }
      end
    end
  end
end
