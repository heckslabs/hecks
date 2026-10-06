module Hecks
  module Fuzzing
    # Shrinks a failing step list to a small one that still reproduces the finding.
    # The caller's block decides "same finding"; this module never replays anything.
    #
    # Pass 1 removes step chunks (delta debugging) until the list is 1-minimal.
    # Pass 2 drops argument keys one at a time inside each surviving step.
    # `budget:` caps candidate checks; when spent, the best candidate so far is returned.
    module Shrinker
      Result = Struct.new(:steps, :attempts, :exhausted, keyword_init: true)

      module_function

      # Shrinks `steps` to the smallest list the block still accepts as reproducing.
      #
      # @param steps [Array<Hash>] the step list to shrink
      # @param budget [Integer, nil] maximum candidate checks to spend; nil for unbounded
      # @yieldparam candidate [Array<Hash>] a step-dropped or argument-trimmed copy of `steps`
      # @yieldreturn [Boolean] true if `candidate` still reproduces the finding
      # @return [Fuzzing::Shrinker::Result] `steps:` the shrunk list, `attempts:` checks
      #   spent, `exhausted:` whether the budget ran out
      # @raise [ArgumentError] if no block is given
      def call(steps, budget: nil, &reproduces)
        raise ArgumentError, "Shrinker.call needs a block answering whether a candidate reproduces" unless reproduces

        meter   = Meter.new(budget)
        current = drop_steps(steps.dup, meter, &reproduces)
        current = drop_arguments(current, meter, &reproduces)
        Result.new(steps: current, attempts: meter.used, exhausted: meter.exhausted?)
      end

      def drop_steps(steps, meter, &reproduces)
        current = steps
        chunk = [current.length / 2, 1].max
        loop do
          swept = sweep(current, chunk, meter, &reproduces)
          changed = swept.length < current.length
          current = swept
          return current if meter.exhausted? || (chunk == 1 && !changed)

          chunk = [chunk / 2, 1].max
        end
      end

      # One pass removing `chunk` steps at a time; a removal that still reproduces is kept.
      #
      # @return [Array<Hash>] the surviving steps
      def sweep(current, chunk, meter, &)
        index = 0
        while index < current.length && !meter.exhausted?
          candidate = without_chunk(current, index, chunk)
          if !candidate.empty? && meter.try { yield(candidate) }
            current = candidate
          else
            index += chunk
          end
        end
        current
      end

      def without_chunk(steps, index, chunk) = steps[0...index] + (steps[(index + chunk)..] || [])

      def drop_arguments(steps, meter, &)
        steps.each_index do |position|
          original = args_of(steps[position])
          next unless original.is_a?(Hash)

          original.each_key do |key|
            return steps if meter.exhausted?

            candidate = without_argument(steps, position, key)
            steps = candidate if meter.try { yield(candidate) }
          end
        end
        steps
      end

      # A copy of `steps` whose step at `position` lacks the argument `key`.
      def without_argument(steps, position, key)
        step = steps[position]
        candidate = steps.map(&:dup)
        candidate[position] = step.merge("args" => args_of(step).reject { |name, _| name == key })
        candidate
      end

      # `key?` first, never `||`, which cannot tell a stored `false` from an absent key.
      def args_of(step)
        step.key?("args") ? step["args"] : step[:args]
      end

      LIST_FIELDS = %w[refusals queries dry_runs reactions].freeze

      CRASH_FIELDS = %w[crash process generator_crash].freeze

      # The identity a shrink candidate has to keep, as a set of stable strings.
      #
      # `field` alone is too loose for list comparisons: a candidate could show a different
      # refusal split and the shrinker would hand back the wrong bug. So list fields add the
      # verbs in the symmetric difference, `instances` adds the differing aggregates, and
      # crash fields add the exception class.
      #
      # @param divergences [Array<Hash>] entries carrying at least `{field:, detail:}`
      # @return [Set<String>] identity strings
      def signature(divergences)
        divergences.each_with_object(Set.new) do |divergence, keys|
          field = divergence[:field].to_s
          keys << field
          keys.merge(detail_keys(field, divergence))
        end
      end

      def detail_keys(field, divergence)
        left, right = divergence.except(:field, :detail).values.select { |v| v.is_a?(Array) || v.is_a?(Hash) }
        if LIST_FIELDS.include?(field) then list_keys(field, left, right)
        elsif field == "instances"     then instance_keys(left, right)
        elsif CRASH_FIELDS.include?(field) && divergence[:detail]
          ["#{field}:#{divergence[:detail].to_s[/\A\w+(?:::\w+)*/]}"]
        else []
        end
      end

      def list_keys(field, left, right)
        return [] unless left.is_a?(Array) && right.is_a?(Array)

        ((left - right) + (right - left)).map { |row| "#{field}:#{named(row)}" }
      end

      # The `#id` suffix is dropped: the generator mints ids, so they name the record,
      # not the finding, and keeping them would pin every creating step.
      def instance_keys(left, right)
        return [] unless left.is_a?(Hash) && right.is_a?(Hash)

        (left.keys | right.keys).reject { |key| left[key] == right[key] }
                                .map { |key| "instances:#{key.to_s.split("#").first}" }
      end

      # True when the candidate's signature contains the original's.
      # Removing steps may add a second divergence but must never lose the one being shrunk.
      def reproduces?(original_signature, divergences)
        !divergences.empty? && original_signature.subset?(signature(divergences))
      end

      def named(row)
        return row.to_s unless row.is_a?(Hash)

        key = [%w[verb query policy], %i[verb query policy]].flatten.find { |name| row.key?(name) }
        (key ? row[key] : row).to_s
      end

      # Counts candidate checks against the budget.
      class Meter
        attr_reader :used

        # @param budget [Integer, nil] maximum candidate checks to allow; nil for unbounded
        def initialize(budget)
          @budget = budget
          @used   = 0
        end

        def exhausted? = !@budget.nil? && @used >= @budget

        # Spends one check against the budget and yields.
        def try
          @used += 1
          yield
        end
      end
    end
  end
end
