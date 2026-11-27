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

      # Each session is played from `<dir>/<tape>.jsonl`, with no model. A session's tape is its
      # own name unless `tapes` names another, so one tape can stand for a session in one run and
      # a differently named session can play a tape written for another run.
      #
      # @param dir [String] the directory of tapes
      # @param binary [String] the `hecks-harness` binary that plays them
      # @param tapes [Hash{String => String}] a session's name to the tape it plays
      # @return [Proc] the launch for a session name
      def replay(dir, binary: Supervisor::BINARY, tapes: {})
        ->(name) { { program: binary, args: ["replay", File.join(dir, "#{tapes.fetch(name, name)}.jsonl")] } }
      end
    end
  end
end
