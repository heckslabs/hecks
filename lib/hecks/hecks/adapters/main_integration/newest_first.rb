# frozen_string_literal: true

require_relative "../git"

module Hecks
  module Adapters
    class MainIntegration
      # The order an advance takes its runs in: the run whose commit stands highest on local main
      # above `origin/main` first, so when the line is free the newest verified landing boards and
      # its train carries every older one, which answers `superseded` at its own turn. A run main
      # does not hold above `origin/main` keeps its place after them. Reads git only.
      class NewestFirst
        # The local branch the runs landed on, and the remote one it is pushed to.
        MAIN = "main"
        REMOTE_MAIN = "origin/main"

        def initialize
          @git = Git.new
          @ranks = {}
        end

        # @param runs [Array<Runs::Run>] the runs, in the order the saga lists them
        # @return [Array<Runs::Run>] the same runs, the newest on main first
        def order(runs)
          last = runs.size
          runs.each_with_index.sort_by { |run, index| [rank_of(run) || last, index] }.map(&:first)
        end

        private

        def rank_of(run) = ranks(run.checkout.empty? ? Dir.pwd : run.checkout)[run.landed]

        # Each commit main holds above `origin/main`, by its distance from main's head.
        def ranks(checkout)
          @ranks[checkout] ||= begin
            done = @git.capture("rev-list", "--topo-order", MAIN, "--not", REMOTE_MAIN, chdir: checkout)
            done.ok? ? distances(done.out) : {}
          end
        end

        def distances(listed) = listed.split("\n").each_with_index.to_h
      end
    end
  end
end
