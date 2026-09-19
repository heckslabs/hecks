module Hecks
  module Fuzzing
    # A failing step list, made small enough to read.
    #
    # `bin/fuzz` always shrank its findings; `bin/qa_sweep` — the loop that
    # actually finds the bugs — never did, so the ledger filled with
    # demonstrations like "seed 25, 25 steps, step 16" and a human cut
    # BUG#40 down to its four real steps by hand. This is `bin/fuzz`'s
    # shrinker lifted out of that script so both callers share it, and
    # made cheaper at the same time: a sweep's candidate check can cost a
    # Rust subprocess (or a real Postgres round trip), where `bin/fuzz`'s
    # only ever cost an in-process replay.
    #
    # The caller owns "same finding". `call` is handed a block that
    # answers true when a candidate step list still reproduces what the
    # original did — `bin/fuzz` compares its own verdict signature,
    # `bin/qa_sweep` compares `Shrinker.signature` of one mode's
    # divergences. This module never replays anything itself, so it has
    # no idea which engine, adapter or comparison it is minimizing for.
    #
    # **Two passes, in order**:
    #
    #   1. Steps, chunks first. Removing one step at a time (what
    #      `bin/fuzz` did) costs O(n²) candidate checks on a sequence
    #      where most steps are irrelevant. Delta-debugging style: try
    #      removing halves, then quarters, … then single steps, keeping
    #      any removal that still reproduces; a single-step pass repeats
    #      until it changes nothing, so the result is 1-minimal (no one
    #      remaining step can be dropped).
    #   2. Arguments, inside each surviving step. Unchanged from `bin/fuzz`
    #      (spec/bin_fuzz_spec.rb pins its accumulation contract): drop
    #      one key at a time from the step's current args, keep it dropped
    #      only while the finding still reproduces.
    #
    # A budget, because a sweep has other targets waiting. `budget:` caps
    # how many candidate checks one call may spend (nil = unbounded, the
    # `bin/fuzz` behaviour). When it runs out the best candidate found so
    # far is returned — every accepted candidate reproduced, so a partial
    # shrink is still a correct, just less small, demonstration.
    module Shrinker
      Result = Struct.new(:steps, :attempts, :exhausted, keyword_init: true)

      module_function

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
          changed = false
          index = 0
          while index < current.length
            return current if meter.exhausted?

            candidate = current[0...index] + (current[(index + chunk)..] || [])
            if candidate.empty?
              index += chunk
              next
            end

            if meter.try { reproduces.call(candidate) }
              current = candidate
              changed = true
            else
              index += chunk
            end
          end

          if chunk > 1
            chunk = [chunk / 2, 1].max
          elsif !changed
            break
          end
        end
        current
      end

      # See the module header's pass 2 — `args` is read by whichever
      # spelling the step actually carries (`key?` first, never `||`,
      # which cannot tell a stored `false` from an absent key).
      def drop_arguments(steps, meter, &reproduces)
        steps.each_index do |position|
          original = args_of(steps[position])
          next unless original.is_a?(Hash)

          original.each_key do |key|
            return steps if meter.exhausted?

            step      = steps[position]
            trimmed   = args_of(step).reject { |name, _| name == key }
            candidate = steps.map(&:dup)
            candidate[position] = step.merge("args" => trimmed)
            steps = candidate if meter.try { reproduces.call(candidate) }
          end
        end
        steps
      end

      def args_of(step)
        step.key?("args") ? step["args"] : step[:args]
      end

      # Which finding this is, as a set of stable strings — the identity a
      # shrink candidate has to keep. The `field` alone is too loose for
      # the comparisons that carry lists: "refusals differ" on a 3-step
      # candidate could be a different refusal split than the one the
      # original seed found, and a shrinker that accepted it would hand
      # back a demonstration of the wrong bug. So:
      #
      #   refusals/queries/dry_runs/reactions — the field plus every verb
      #     (or query) named in the symmetric difference of the two sides;
      #   instances — the field plus the aggregate of every top-level key
      #     whose two sides disagree (the `#id` suffix dropped);
      #   a crash/process finding — the field plus the exception class
      #     leading its detail;
      #   anything else (a property name, a self-consistency axis) — the
      #     field, which already names the finding.
      #
      # `reproduces?` holds when a candidate's signature contains the
      # original's: removing steps may add a second divergence, but it
      # must never lose the one being demonstrated.
      LIST_FIELDS = %w[refusals queries dry_runs reactions].freeze

      CRASH_FIELDS = %w[crash process generator_crash].freeze

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

      # Instance keys are `Aggregate#id` on the wire — the id is whatever
      # the generator minted, so it names the record, not the finding;
      # keeping it would pin every creating step.
      def instance_keys(left, right)
        return [] unless left.is_a?(Hash) && right.is_a?(Hash)

        (left.keys | right.keys).reject { |key| left[key] == right[key] }
                                .map { |key| "instances:#{key.to_s.split('#').first}" }
      end

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

        def initialize(budget)
          @budget = budget
          @used   = 0
        end

        def exhausted? = !@budget.nil? && @used >= @budget

        def try
          @used += 1
          yield
        end
      end
    end
  end
end
