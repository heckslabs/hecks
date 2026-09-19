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
    # ## Ownership of "same finding"
    #
    # The caller owns it. `call` is handed a block that
    # answers true when a candidate step list still reproduces what the
    # original did — `bin/fuzz` compares its own verdict signature,
    # `bin/qa_sweep` compares `Shrinker.signature` of one mode's
    # divergences. This module never replays anything itself, so it has
    # no idea which engine, adapter or comparison it is minimizing for.
    #
    # ## Two passes, in order
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
    # ## Budget
    #
    # A budget, because a sweep has other targets waiting. `budget:` caps
    # how many candidate checks one call may spend (nil = unbounded, the
    # `bin/fuzz` behaviour). When it runs out the best candidate found so
    # far is returned — every accepted candidate reproduced, so a partial
    # shrink is still a correct, just less small, demonstration.
    module Shrinker
      Result = Struct.new(:steps, :attempts, :exhausted, keyword_init: true)

      module_function

      # Shrinks `steps` to the smallest step list the block still accepts as
      # reproducing the original finding — pass 1 (steps), then pass 2
      # (arguments), as this module's own header describes.
      #
      # @param steps [Array<Hash>] the step list to shrink, each step a command,
      #   query, or read-model hash as `SequenceGenerator` produces
      # @param budget [Integer, nil] maximum candidate checks to spend; nil for
      #   unbounded
      # @yield [candidate] tests whether a candidate step list still reproduces
      #   the finding being shrunk
      # @yieldparam candidate [Array<Hash>] a step-dropped or argument-trimmed
      #   copy of `steps`
      # @yieldreturn [Boolean] true if `candidate` still reproduces the finding
      # @return [Fuzzing::Shrinker::Result] `steps:` the shrunk step list,
      #   `attempts:` how many candidate checks were spent, `exhausted:` whether
      #   the budget ran out before shrinking finished
      # @raise [ArgumentError] if no block is given
      def call(steps, budget: nil, &reproduces)
        raise ArgumentError, "Shrinker.call needs a block answering whether a candidate reproduces" unless reproduces

        meter   = Meter.new(budget)
        current = drop_steps(steps.dup, meter, &reproduces)
        current = drop_arguments(current, meter, &reproduces)
        Result.new(steps: current, attempts: meter.used, exhausted: meter.exhausted?)
      end

      # Runs pass 1 of the shrink: delta-debugging removal of step chunks,
      # halving the chunk size each full pass until single steps are tried
      # and nothing more can be dropped.
      #
      # @param steps [Array<Hash>] the step list to shrink
      # @param meter [Fuzzing::Shrinker::Meter] the shared budget meter
      # @yield [candidate] tests whether a candidate step list still reproduces
      #   the finding being shrunk
      # @yieldparam candidate [Array<Hash>] `steps` with one chunk removed
      # @yieldreturn [Boolean] true if `candidate` still reproduces the finding
      # @return [Array<Hash>] the smallest step list pass 1 could reach, or the
      #   best found so far if the budget ran out first
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

      # Runs pass 2 of the shrink: drops one argument key at a time from
      # each surviving step's args, keeping the drop only while the
      # finding still reproduces.
      #
      # See the module header's pass 2 — `args` is read by whichever
      # spelling the step actually carries (`key?` first, never `||`,
      # which cannot tell a stored `false` from an absent key).
      #
      # @param steps [Array<Hash>] the step list, already step-shrunk by `drop_steps`
      # @param meter [Fuzzing::Shrinker::Meter] the shared budget meter
      # @yield [candidate] tests whether a candidate step list still reproduces
      #   the finding being shrunk
      # @yieldparam candidate [Array<Hash>] `steps` with one step's one argument
      #   key dropped
      # @yieldreturn [Boolean] true if `candidate` still reproduces the finding
      # @return [Array<Hash>] `steps` with every argument key `drop_arguments`
      #   accepted dropped
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

      # Reads a step's argument hash, whichever key spelling it uses.
      #
      # @param step [Hash] one step, string- or symbol-keyed
      # @return [Hash, nil] the step's `"args"` value if the step is string-keyed,
      #   else its `:args` value (nil if neither key is present)
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

      # Computes which finding a set of divergences is — the stable identity
      # a shrink candidate has to keep. See this method's own preceding
      # comment for what each field kind contributes.
      #
      # @param divergences [Array<Hash>] divergence entries, each at least
      #   `{field:, detail:}` plus whichever mode-specific keys carry the two
      #   compared sides
      # @return [Set<String>] stable identity strings: each divergence's `field`,
      #   plus `detail_keys`' own per-field detail strings
      def signature(divergences)
        divergences.each_with_object(Set.new) do |divergence, keys|
          field = divergence[:field].to_s
          keys << field
          keys.merge(detail_keys(field, divergence))
        end
      end

      # Extracts the finer-grained identity strings one divergence's field
      # contributes beyond the field name itself.
      #
      # @param field [String] the divergence's `field`, stringified
      # @param divergence [Hash] the divergence entry `field` came from
      # @return [Array<String>] extra identity strings for `field`'s own kind
      #   (list, `instances`, or crash/process); empty for any other field
      def detail_keys(field, divergence)
        left, right = divergence.except(:field, :detail).values.select { |v| v.is_a?(Array) || v.is_a?(Hash) }
        if LIST_FIELDS.include?(field) then list_keys(field, left, right)
        elsif field == "instances"     then instance_keys(left, right)
        elsif CRASH_FIELDS.include?(field) && divergence[:detail]
          ["#{field}:#{divergence[:detail].to_s[/\A\w+(?:::\w+)*/]}"]
        else []
        end
      end

      # Names the rows present on one side of a list-field divergence and not
      # the other.
      #
      # @param field [String] the divergence's field name, prefixed onto each key
      # @param left [Array, nil] one side's list; a non-Array yields no keys
      # @param right [Array, nil] the other side's list; a non-Array yields no keys
      # @return [Array<String>] `"field:name"` for every row in the symmetric
      #   difference of `left` and `right`; empty unless both are arrays
      def list_keys(field, left, right)
        return [] unless left.is_a?(Array) && right.is_a?(Array)

        ((left - right) + (right - left)).map { |row| "#{field}:#{named(row)}" }
      end

      # Names the top-level keys the two sides of an `instances` divergence
      # disagree on.
      #
      # Instance keys are `Aggregate#id` on the wire — the id is whatever
      # the generator minted, so it names the record, not the finding;
      # keeping it would pin every creating step.
      #
      # @param left [Hash, nil] one side's instance snapshot; a non-Hash yields no keys
      # @param right [Hash, nil] the other side's instance snapshot; a non-Hash
      #   yields no keys
      # @return [Array<String>] `"instances:Aggregate"` for every top-level key
      #   the two sides disagree on, its `#id` suffix dropped; empty unless both
      #   are hashes
      def instance_keys(left, right)
        return [] unless left.is_a?(Hash) && right.is_a?(Hash)

        (left.keys | right.keys).reject { |key| left[key] == right[key] }
                                .map { |key| "instances:#{key.to_s.split('#').first}" }
      end

      # Checks that a candidate's own divergences still demonstrate the
      # finding being shrunk.
      #
      # @param original_signature [Set<String>] the finding's own signature, as
      #   returned by `signature`
      # @param divergences [Array<Hash>] the candidate's own divergence entries,
      #   in `signature`'s own shape
      # @return [Boolean] true if `divergences` is non-empty and its signature is
      #   a superset of `original_signature`
      def reproduces?(original_signature, divergences)
        !divergences.empty? && original_signature.subset?(signature(divergences))
      end

      # Names one row from a list-field divergence, for `list_keys`.
      #
      # @param row [Object] one item from a list-field divergence's array;
      #   typically a Hash carrying a `verb`, `query`, or `policy` key (string
      #   or symbol)
      # @return [String] `row`'s `verb`/`query`/`policy` value, stringified, if
      #   `row` is a Hash carrying one of those keys; otherwise `row.to_s`
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

        # Reports whether this meter's budget has been fully spent.
        #
        # @return [Boolean] true if a budget is set and every allotted check has
        #   been used
        def exhausted? = !@budget.nil? && @used >= @budget

        # Spends one candidate check against the budget and runs the block.
        #
        # @yield runs the candidate check being counted
        # @yieldreturn [Object] the block's own result
        # @return [Object] whatever the block returns
        def try
          @used += 1
          yield
        end
      end
    end
  end
end
