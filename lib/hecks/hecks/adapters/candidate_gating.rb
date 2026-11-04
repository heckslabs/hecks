# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "candidate_gate"
require_relative "candidate_marker"
require_relative "candidate_gating/repository"
require_relative "candidate_gating/ci_reading"
require_relative "candidate_gating/observation"
require_relative "candidate_gating/promotion"
require_relative "candidate_gating/rejection"

module Hecks
  module Adapters
    # The `Gating` port's adapter for `Candidate` (ADR 0181): reads the candidate against the
    # remote and GitHub, fast-forwards main onto a green one from here, clears a red one, switches
    # the gate, and reads its status. The candidate's record is `CandidateMarker`'s file; the
    # switch is the repository's git configuration; main is pushed only as a fast-forward and
    # only through the pre-push hook, carrying the promotion it reads.
    class CandidateGating
      class << self
        # @return [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the command
        #   runner when nil. A spec replaces it with a fake GitHub.
        attr_accessor :runner
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] the booted registry: the gate's default and the
      #   Tickets a rejection files Work items into
      # @param tune [Hash] `checkout:` the repository, `runner:` what runs `gh` (a spec's fake
      #   GitHub) and `clock:` for the marker
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil, **tune)
        @registry = registry
        @tune = tune
        @git = Git.new
      end

      # @param held [Hash] the `Candidate` record: `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`promoted`, `red`, `running` or `idle`) and
      #   the candidate's facts
      # @raise [ConsoleCapture::Failure] when the repository or `gh` cannot be read
      def look(**held) = Observation.new(parts(held)).answer

      # @param held [Hash] the `Candidate` record: `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` `promoted`
      # @raise [ConsoleCapture::Failure] when there is no candidate, it is not green, or the push
      #   is refused
      def forward(**held) = Promotion.new(parts(held)).answer

      # @param held [Hash] the `Candidate` record: `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` `rejected`, the branch, the Work items and the
      #   authors
      # @raise [ConsoleCapture::Failure] when there is no candidate, it is not red, or local main
      #   is not clean
      def clear(**held) = Rejection.new(parts(held), registry: @registry).answer

      # @param held [Hash] the `Candidate` record: `setting` (`on` or `off`) and `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` `switched` and the setting
      def flip(**held)
        on = plain(held[:setting]).to_s == "on"
        gate(held).switch!(on)
        said = on ? "the push train now queues a candidate and main moves only by promotion" : "the train pushes main as before"
        { outcome: { value: "switched" }, setting: { value: on ? "on" : "off" },
          report: { value: "candidate gate #{on ? "on" : "off"} for #{checkout(held)}: #{said}" } }
      end

      # @param held [Hash] `checkout`
      # @return [Hash{Symbol => String}] `text:` the gate and the candidate in words
      def status(**held)
        gate = gate(held)
        candidate = CandidateMarker.new(Repository.new(@git, checkout(held)).git_dir).read
        lines = ["candidate gate #{gate.on? ? "on" : "off"} (#{gate.source})", *candidate_lines(candidate)]
        { text: "#{lines.join("\n")}\n" }
      end

      private

      def candidate_lines(candidate)
        return ["no candidate recorded"] unless candidate

        ["candidate #{candidate["sha"]}: #{candidate["state"]}, #{candidate["commits"]} commit(s) on #{candidate["base"]}",
         *(candidate["ci_run"] && "CI run #{candidate["ci_run"]}#{" failed jobs: #{candidate["jobs"]}" if candidate["jobs"]}"),
         *(candidate["branch"] && "kept on #{candidate["branch"]}")].compact
      end

      def parts(held)
        repository = Repository.new(@git, checkout(held))
        { repository: repository, marker: CandidateMarker.new(repository.git_dir, **@tune.slice(:clock)),
          ci: CiReading.new(checkout(held), runner: @tune[:runner] || self.class.runner), checkout: checkout(held) }
      end

      def gate(held) = CandidateGate.new(checkout(held), registry: @registry, git: @git)

      def checkout(held) = plain(held[:checkout]) || @tune[:checkout] || Dir.pwd

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
