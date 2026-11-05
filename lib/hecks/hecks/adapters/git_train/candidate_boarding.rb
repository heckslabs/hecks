# frozen_string_literal: true

require_relative "reading"
require_relative "bench"
require_relative "local_branch"
require_relative "../candidate_marker"
require_relative "../candidate_gate"
require_relative "../green_trees"

module Hecks
  module Adapters
    class GitTrain
      # One boarding's work while the candidate gate is on (ADR 0181): the boarded commit goes to
      # the remote's candidate ref, not to main, and main moves only once CI passed on it. One
      # candidate is in flight at a time: a boarding while one is queued, green or red is refused
      # by name, so two untested heads are never stacked. A commit whose tree CI already passed
      # on (a past green main or candidate) is promoted at once, with no run of its own: it is
      # pushed to main as the promotion the pre-push hook lets through.
      #
      # The candidate ref is a scratch pointer and is moved over a settled one (promoted or
      # rejected); main is never forced.
      class CandidateBoarding
        include Reading

        # The git configuration a promotion push carries, which the pre-push hook reads.
        PROMOTION = "hecks.candidatePromotion"

        # What a refusal for a candidate in flight ends with.
        NEXT = "candidate Candidate.observe! reads it; candidate Candidate.reject! clears a red one"

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param remote [String] the remote the candidate is pushed to
        # @param config [Array<String>] `-c name=value` words for the push, read by the hook
        # @param runner [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]` for `gh`
        def initialize(git, checkout, remote:, config: [], runner: nil)
          @git = git
          @checkout = checkout
          @remote = remote
          @config = config
          @runner = runner
          @marker = CandidateMarker.new(read("rev-parse", "--path-format=absolute", "--git-common-dir"))
        end

        # Carries one commit: queues it as the candidate, promotes it at once when its tree is
        # already green, or finds it already on main.
        #
        # @param boarded [String] the commit to carry, which local main must still name
        # @return [Hash{Symbol => Hash}] the answer `GitTrain#carry` describes, with `outcome:`
        #   `queued`, `pushed` (a tree-match promotion) or `carried`
        # @raise [ConsoleCapture::Failure] when a candidate is in flight, the branch moved since
        #   boarding, the commit is not built on the remote's main, or the push is refused
        def carry(boarded)
          fetch
          moved_since!(boarded)
          return carried(boarded) if ancestor?(boarded, main)

          in_flight!
          built_on_main!(boarded)
          green = GreenTrees.new(@git, @checkout, runner: @runner).match(boarded)
          green ? promote(boarded, green) : queue(boarded)
        end

        private

        def fetch
          read("fetch", "--quiet", @remote, "+refs/heads/main:refs/remotes/#{main}")
          @git.capture("fetch", "--quiet", @remote, "+refs/heads/#{branch}:refs/remotes/#{candidate}", chdir: @checkout)
        end

        def moved_since!(boarded)
          now = read("rev-parse", "--verify", "refs/heads/main^{commit}")
          return if now == boarded

          raise ConsoleCapture::Failure, "main moved since boarding (boarded #{short(boarded)}, now #{short(now)}): board again"
        end

        # A candidate still in flight, by the record or by the remote's ref, refuses a boarding.
        def in_flight!
          settle_promoted
          refuse_recorded!(@marker.read) if @marker.in_flight?
          refuse_remote!(remote_candidate)
        end

        # A recorded candidate the remote's main already holds was promoted meanwhile.
        def settle_promoted
          recorded = @marker.read
          return unless recorded && ancestor?(recorded["sha"].to_s, main)

          @marker.note!("promoted", via: "observed at boarding")
        end

        def refuse_recorded!(recorded)
          run = recorded["ci_run"].to_s.empty? ? "run not yet known" : "run #{recorded["ci_run"]}"
          raise ConsoleCapture::Failure,
                "candidate #{short(recorded["sha"].to_s)} is in flight: #{run} (#{recorded["state"]}); #{NEXT}"
        end

        # A remote candidate ref ahead of main that no record names (another machine boarded it).
        def refuse_remote!(remote)
          return if remote.nil? || ancestor?(remote, main) || @marker.read&.dig("sha") == remote

          raise ConsoleCapture::Failure, "candidate #{short(remote)} is in flight on #{candidate} (no local record); #{NEXT}"
        end

        def built_on_main!(boarded)
          return if ancestor?(main, boarded)

          raise ConsoleCapture::Failure, "#{main} moved since #{short(boarded)} was settled: it is not built on it; board again"
        end

        def queue(boarded)
          base = read("rev-parse", main)
          pushed = bench(branch).push(boarded, candidate, base: main, force: true)
          raise ConsoleCapture::Failure, "#{candidate} moved while the candidate was pushed; board again" if pushed == :moved

          count = read("rev-list", "--count", "#{base}..#{boarded}").to_i
          @marker.queue!(sha: boarded, base: base, commits: count)
          answer("queued", boarded, nil, queued_report(boarded, base, count))
        end

        def queued_report(boarded, base, count)
          "candidate #{short(boarded)} queued on #{candidate}: #{count} commit(s) on #{short(base)}; CI runs there, " \
            "and main moves when it is green (candidate Candidate.observe! reads it)"
        end

        # A tree CI already passed on goes straight to main, as a promotion.
        def promote(boarded, green)
          pushed = bench("main", config: ["-c", "#{PROMOTION}=#{boarded}"]).push(boarded, main)
          raise ConsoleCapture::Failure, "#{main} moved while #{short(boarded)} was promoted; board again" if pushed == :moved

          @marker.queue!(sha: boarded, base: green, commits: 0)
          @marker.note!("promoted", via: "tree match with #{green}")
          local = LocalBranch.new(@git, @checkout, "main").catch_up(boarded)
          answer("pushed", boarded, boarded, "#{short(boarded)} promoted to #{main} with no CI run: its tree is the one " \
                                             "CI passed on at #{short(green)}; #{local}")
        end

        def bench(name, config: [])
          Bench.new(@git, @checkout, branch: name, remote: @remote, config: [*@config, *config])
        end

        def carried(boarded)
          answer("carried", boarded, nil, "#{short(boarded)} is already on #{main}: an earlier push carried it")
        end

        def answer(outcome, boarded, pushed, report)
          { outcome: { value: outcome }, checkout: { value: @checkout }, boarded: { value: boarded },
            pushed: pushed && { value: pushed }, report: { value: report } }.compact
        end

        def remote_candidate
          done = @git.capture("rev-parse", "--verify", "--quiet", "#{candidate}^{commit}", chdir: @checkout)
          done.ok? ? done.out.strip : nil
        end

        def branch = CandidateGate::BRANCH

        def main = "#{@remote}/main"

        def candidate = "#{@remote}/#{branch}"
      end
    end
  end
end
