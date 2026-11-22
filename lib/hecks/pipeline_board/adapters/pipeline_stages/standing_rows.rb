# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # Turns what git said of each worktree into `ChangeStanding` rows. The standing and its words
      # come from the `Standing` Verdict rows and the `StandingSays` rows, not from here.
      module StandingRows
        module_function

        # @param facts [Array<Hash>] each worktree's `subject`, `branch`, `path`, `lacks_origin`
        #   and `lacks_main` (the shas), and `dirty`
        # @return [Array<Hash>] one `ChangeStanding` per worktree
        def build(facts) = facts.map { |fact| row(fact) }

        def row(fact)
          standing = Rules.verdict("Standing", lacks_origin: fact[:lacks_origin].size, lacks_main: fact[:lacks_main].size)
          fact.slice(:subject, :branch, :path, :dirty).merge(standing: standing, say: says(standing), shas: shas(fact, standing))
        end

        def says(standing) = words(standing)&.fetch(:says).to_s

        def words(standing) = Rules.rows("StandingSays").find { |row| row[:standing] == standing }

        def shas(fact, standing)
          held = { "worktree" => fact[:lacks_main], "local_main" => fact[:lacks_origin] }.fetch(standing, [])
          held.join(" ")
        end
      end
    end
  end
end
