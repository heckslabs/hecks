# frozen_string_literal: true

require "hecks/ci_speed/adapters/local_runner/refused"
require "hecks/ci_speed/adapters/local_runner/refs"
require "hecks/ci_speed/adapters/local_runner/catalog"
require "hecks/ci_speed/adapters/local_runner/checkouts"
require "hecks/ci_speed/adapters/local_runner/launcher"
require "hecks/ci_speed/adapters/local_runner/load_average"
require "hecks/ci_speed/adapters/local_runner/verdict"
require "hecks/ci_speed/adapters/local_runner/answer"

module Hecks
  module Adapters
    # The `LocalRunner` port's adapter: times a definition's steps in two temporary checkouts, one
    # of the base ref and one of the candidate ref, and answers with the numbers.
    #
    # Each side first runs every step once untimed, so the build caches a fresh checkout lacks are
    # paid before timing starts. The steps then run interleaved, base then candidate then base
    # again, so a change in the machine's load while the experiment runs lands on both sides. A
    # step the machine cannot stand in for is named in `unmeasured` and left out of both sides.
    # Both checkouts are removed when the run ends, however it ends, and the checkout that asked
    # is never written.
    class LocalRunner
      # The sides of an experiment, in the order a round samples them.
      SIDES = %i[base candidate].freeze

      # What a step's `needs` can be and still run on this machine.
      LOCAL_NEEDS = %w[none].freeze

      # The samples taken when an experiment names no number.
      DEFAULT_REPEATS = 3

      # One side of an experiment: which it is, its checkout, and the launcher that runs its steps.
      Side = Struct.new(:name, :path, :launcher)

      # @return [Array<Hash>] every sample in the order it was taken: its round, side, seconds and
      #   the checkout it ran in
      attr_reader :trail

      # @return [Array<Hash>] the untimed pass in each checkout before sampling began: its side
      #   and the seconds it took, which no verdict uses
      attr_reader :warm_up

      # @param registry [Runtime::Registry, nil] the booted registry whose CiSpeed chapter holds
      #   the definitions; unused when `catalog` is given
      # @param catalog [Catalog, nil] the definitions to read instead of the chapter's rows
      # @param root [String, nil] the checkout that asks, whose refs are resolved and whose
      #   generated tree is copied; this repository when nil
      # @param scratch [String, nil] where the temporary checkouts are made; `$CLAUDE_JOB_DIR/tmp`
      #   when that is set, else the system's temporary directory
      def initialize(registry: nil, catalog: nil, root: nil, scratch: nil)
        @registry = registry
        @catalog = catalog
        @root = root || File.expand_path("../../../..", __dir__)
        @scratch = scratch || job_scratch
        @trail = []
        @warm_up = []
      end

      # Runs the experiment named by `held`.
      #
      # @param held [Hash] the `Experiment` record: `measures`, `cache_state`, `base_ref`,
      #   `candidate_ref`, `repeats` and `lever` when set
      # @return [Hash{Symbol => Hash}] the answer, each field in the shape `Experiment::Complete`
      #   takes: the times, the spread and saving, the load, what went unmeasured, the verdict,
      #   what it rests on, and the lever to tell with the estimate it should hold
      # @raise [Refused] when the definition is unknown, disagrees with the experiment about the
      #   cache state, no step can be measured, a ref does not resolve, or a step ends badly
      def measure(**held)
        asked = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
        definition = definition_for(asked)
        shas = Refs.resolve(@root, asked)
        load = LoadAverage.now
        sampled = sample_both(definition, shas, asked[:repeats] || DEFAULT_REPEATS)
        answer(asked, definition, sampled, load)
      end

      private

      def definition_for(asked)
        definition = catalog.fetch(asked.fetch(:measures))
        return definition if definition.cache_state == asked.fetch(:cache_state)

        raise Refused, "#{definition.name} measures cache state #{definition.cache_state}, " \
                       "but the experiment stands for #{asked.fetch(:cache_state)}"
      end

      def catalog
        @catalog ||= Catalog.from_chapter(@registry&.bluebook("CiSpeed") || raise(Refused, "no CiSpeed chapter is booted"))
      end

      # Checks the two sides out, works out which steps both can run, and samples them interleaved.
      def sample_both(definition, shas, repeats)
        copy_from = @root if definition.generated_tree?
        refuse_missing_tree(copy_from)
        Checkouts.with(root: @root, shas: shas, scratch: @scratch) do |paths|
          sides = paths.map { |name, path| Side.new(name, path, Launcher.new(path)) }
          steps, unmeasured = measurable(definition.steps, sides)
          warm(sides, steps, copy_from)
          { unmeasured: unmeasured, samples: rounds(sides, steps, copy_from, repeats) }
        end
      end

      # Runs every step once in each checkout before anything is timed. A fresh checkout holds no
      # build caches, and the first run in it would pay for them on one side of the first pair.
      def warm(sides, steps, copy_from)
        sides.each do |side|
          Checkouts.reset_generated_tree(side.path, copy_from)
          seconds = steps.sum { |step| side.launcher.time(step) }
          @warm_up << { side: side.name, seconds: seconds }
        end
      end

      # Splits steps into those both sides can run here and a note for each that cannot.
      def measurable(steps, sides)
        notes = []
        kept = steps.select do |step|
          reason = unmeasurable(step, sides)
          notes << "#{step.name}: #{reason}" if reason
          reason.nil?
        end
        raise Refused, "no step could be measured here: #{notes.join("; ")}" if kept.empty?

        [kept, notes]
      end

      def unmeasurable(step, sides)
        return "needs #{step.needs}, which a local run does not stand in for" unless LOCAL_NEEDS.include?(step.needs)

        sides.each do |side|
          return "#{step.verb} or an argument it is given is unknown to the #{side.name} ref" unless side.launcher.knows?(step)
        end
        nil
      end

      # One round samples each side once, base first, and the rounds follow one another.
      def rounds(sides, steps, copy_from, repeats)
        taken = Array.new(repeats) { |round| sides.map { |side| sample(round, side, steps, copy_from) } }
        taken.flatten.group_by { |sample| sample[:side] }.transform_values { |own| own.map { |one| one[:seconds] } }
      end

      def refuse_missing_tree(copy_from)
        return if copy_from.nil? || File.directory?(File.join(copy_from, Checkouts::GENERATED_TREE))

        raise Refused, "the definition needs a generated tree, and #{copy_from} holds none at #{Checkouts::GENERATED_TREE}"
      end

      def sample(round, side, steps, copy_from)
        Checkouts.reset_generated_tree(side.path, copy_from)
        seconds = steps.sum { |step| side.launcher.time(step) }
        taken = { round: round, side: side.name, seconds: seconds, checkout: side.path }
        @trail << taken
        taken
      end

      def answer(asked, definition, sampled, load)
        verdict = Verdict.new(base: sampled[:samples].fetch(:base), candidate: sampled[:samples].fetch(:candidate))
        Answer.build(asked: asked, definition: definition.name, verdict: verdict, load: load,
                     unmeasured: sampled[:unmeasured])
      end

      def job_scratch
        job = ENV.fetch("CLAUDE_JOB_DIR", nil)
        File.join(job, "tmp") if job && !job.empty?
      end
    end
  end
end
