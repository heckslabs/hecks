# frozen_string_literal: true

require "json"
require_relative "spec_map"
require_relative "impacted/spec_run"
require_relative "impacted/skips"

module Hecks
  module Adapters
    class GitRehearsal
      # The stage that runs the specs a push's changes touch, in the rehearsal's copy of the commit.
      #
      # The changed files are those between the remote tracking ref and the commit; `SpecMap` names
      # the specs they affect, each is run alone through the launcher, and one that is red turns the
      # stage red unless it is red on the remote tracking ref too (run in a second detached copy,
      # made only when something failed), which is reported as pre-existing and passes.
      #
      # A file that fails among the others is run again alone, once, when nothing else of the stage
      # runs: one that passes then is flaky under parallel load, reported by name and counted in
      # the rehearsal record, and does not turn the stage red; one that fails alone is red.
      class Impacted
        # The stage's name in the report.
        NAME = "impacted specs"

        # The most spec files a rehearsal runs.
        DEFAULT_LIMIT = 60

        # How many spec files run at once.
        DEFAULT_WIDTH = 2

        # What the stage works with.
        #
        # @!attribute [r] git
        #   @return [Git] the adapter every git call goes through
        # @!attribute [r] run
        #   @return [SpecRun] runs one spec file in a directory
        # @!attribute [r] skips
        #   @return [Skips] decides which specs cannot run here
        # @!attribute [r] bench
        #   @return [#call] given a commit and a block, yields a second copy of it
        # @!attribute [r] flakes
        #   @return [#call, nil] given flaky files, counts them in the record, answers each count
        Tools = Struct.new(:git, :run, :skips, :bench, :flakes)

        # @param directory [String] the copy of the commit
        # @param branch [String] the branch pushed; its remote tracking ref is `origin/<branch>`
        # @param tools [Tools] what the stage works with
        # @param limit [Integer] the most spec files to run
        # @param width [Integer] how many spec files run at once
        def initialize(directory, branch:, tools:, limit: DEFAULT_LIMIT, width: DEFAULT_WIDTH)
          @directory = directory
          @remote = "origin/#{branch}"
          @git = tools.git
          @run = tools.run
          @skips = tools.skips
          @bench = tools.bench
          @flakes = tools.flakes
          @limit = limit
          @width = [width.to_i, 1].max
        end

        # The stage as a rehearsal runs it.
        #
        # @param directory [String] the copy of the commit
        # @param branch [String] the branch being pushed
        # @param capture [#call] given a directory, a command and `env:`, runs it there
        # @param limit [Integer, nil] the most spec files to run; the default when nil
        # @param width [Integer, nil] how many run at once; the default when nil
        # @return [Impacted]
        def self.build(directory, branch:, capture:, limit: nil, width: nil)
          git = Git.new
          scratch = -> { capture.call(directory, "pg_isready", env: {}).ok? }
          bench = ->(commit, &block) { Bench.new(git, directory).rehearse(commit, &block) }
          flakes = ->(names) { Record.new(git, directory).count_flakes(names) }
          tools = Tools.new(git, SpecRun.new(capture), Skips.new(directory, scratch: scratch), bench, flakes)
          new(directory, branch: branch, tools: tools, limit: limit || DEFAULT_LIMIT, width: width || DEFAULT_WIDTH)
        end

        # @return [Stages::Result] the stage's result
        def result
          base = commit(@remote)
          return Stages::Result.new(NAME, true, " (no #{@remote} to compare with)") unless base

          mapping = SpecMap.new(@directory).map(changed(base), limit: @limit, skip: @skips)
          verdict(mapping, base)
        end

        private

        def verdict(mapping, base)
          outcomes = run_all(mapping.specs)
          flaky, red = alone(outcomes.reject(&:passed))
          known, fresh = red.partition { |outcome| red_on_base?(outcome, base) }
          notes = notes(mapping, outcomes.size, known) + flaky_notes(flaky)
          fresh.empty? ? Stages::Result.new(NAME, true, notes_in_brackets(notes)) : failed(fresh, notes)
        end

        def failed(fresh, notes) = Stages::Result.new(NAME, false, ([fresh.map(&:line).join("; ")] + notes).join("; "))

        # Runs each failed file again alone, after the batch; answers the specs that then passed and
        # the outcomes of those that failed again.
        def alone(failed)
          again = failed.map { |outcome| @run.call(@directory, outcome.spec, io: @skips.io?(outcome.spec)) }
          flaky, red = again.partition(&:passed)
          [flaky.map(&:spec), red]
        end

        def flaky_notes(flaky)
          counts = counted(flaky)
          flaky.map do |spec|
            times = counts[spec].to_i
            "flaky under parallel load: #{spec}#{" (flaky in #{times} rehearsals)" if times > 1}"
          end
        end

        # How many rehearsals each flaky file has been flaky in; empty when the record cannot say.
        def counted(flaky)
          return {} if flaky.empty? || @flakes.nil?

          @flakes.call(flaky)
        rescue StandardError
          {}
        end

        def notes(mapping, ran, known)
          [("#{ran} spec file(s) run" if ran.positive?), mapping.cap_note, *skipped(mapping),
           ("pre-existing red: #{known.map(&:spec).join(", ")}" unless known.empty?)].compact.reject(&:empty?)
        end

        def skipped(mapping)
          mapping.skipped.group_by { |_spec, why| why }.map { |why, specs| "skipped: #{why} (#{specs.size})" }
        end

        def notes_in_brackets(notes) = notes.empty? ? " (nothing impacted)" : " (#{notes.join("; ")})"

        def changed(base)
          out = @git.capture("diff", "--name-only", "--diff-filter=d", base, "HEAD", chdir: @directory)
          out.ok? ? paths(out.out) : []
        end

        def paths(text) = text.lines.map(&:strip).reject(&:empty?)

        def commit(ref)
          out = @git.capture("rev-parse", "--verify", "--quiet", "#{ref}^{commit}", chdir: @directory)
          out.ok? ? out.out.strip : nil
        end

        def run_all(specs)
          queue = Queue.new
          specs.each_with_index { |spec, index| queue << [spec, index] }
          found = Array.new(specs.size)
          Array.new([@width, specs.size].min) { Thread.new { work(queue, found) } }.each(&:join)
          found
        end

        def work(queue, found)
          loop do
            spec, index = queue.pop(true)
            found[index] = @run.call(@directory, spec, io: @skips.io?(spec))
          end
        rescue ThreadError
          nil
        end

        # Whether the spec is red on the remote tracking ref too: it exists there and fails there.
        def red_on_base?(outcome, base)
          @base_outcomes ||= {}
          @base_outcomes.fetch(outcome.spec) do
            @base_outcomes[outcome.spec] = on_base(outcome.spec, base)
          end
        end

        def on_base(spec, base)
          @bench.call(base) do |directory|
            File.exist?(File.join(directory, spec)) && !@run.call(directory, spec, io: @skips.io?(spec)).passed
          end
        end
      end
    end
  end
end
