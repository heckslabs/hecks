# frozen_string_literal: true

require_relative "gate_marker"

module Hecks
  module Adapters
    class GitLanding
      # What landing on main asks beyond any other landing: a base that is not behind origin. The
      # including class answers `common_git_dir`, `@git` and `refuse_stale_base`.
      module MainBase
        include GateMarker::Gating

        private

        # @return [Object] what the block answers, run only after main's base check passes
        def on_main(branch, onto)
          return yield unless onto == "main"

          refuse_stale_base(branch)
          yield
        end
      end
    end
  end
end
