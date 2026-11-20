# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # The first merge, among the landings a failed verification covers, at which the failing
      # specs are red: a binary search over the merges oldest first, one probe per step. It reads
      # facts and writes none: nothing is reverted, marked or raised here, and a probe that errors
      # or a spent budget answers nil with a `reason`, never an exception. The merges are the
      # landings between two fixed commits, so a head that moved meanwhile changes nothing.
      #
      # The search assumes a failure stays once it appears, which holds because a probe runs the
      # failing specs themselves at the merge, not the specs the merge's own paths touch. When a
      # later merge mends it, the answer is still the first merge that failed, which the mend may
      # already have fixed.
      class FirstBad
        # The most probes one search makes; each is a clean copy and an impacted-spec run. A failing
        # merge is probed a second time before it is blamed, so the worst case is twice the steps of
        # a six-step search.
        LIMIT = 12

        # @param merges [Array<Hash>] the landings, oldest first (`Repository#merges`)
        # @param probe [#call] given a merge, answers `[ok, finding]`; `finding` is a Hash with
        #   `:spec` and `:example` when it failed
        # @param limit [Integer] the most probes to make
        def initialize(merges, probe:, limit: LIMIT)
          @merges = merges
          @probe = probe
          @limit = limit
        end

        # @return [String] why the last search answered nil
        attr_reader :reason

        # @return [Array<String>] the merges that failed one probe and passed the next: reported as
        #   a fact, never blamed
        attr_reader :flaky

        # @return [Array<String>] each probe made, in order: the merge and whether it was `green`
        #   or `red` there
        attr_reader :log

        # @return [Hash, nil] the merge (`sha:`, `subject:`, `paths:`) with its `finding:`, or nil
        #   when none failed or the search could not finish (`reason` says which)
        def call
          start
          step while @low <= @high
          conclude
        rescue StandardError, ConsoleCapture::Failure => e
          @reason = "the search stopped: #{e.message}"
          nil
        end

        private

        def start
          @low = 0
          @high = @merges.size - 1
          @found = nil
          @spent = 0
          @flaky = []
          @log = []
        end

        def conclude
          @reason = "no merge in the range turns the failing specs red" unless @found
          @found
        end

        def step
          middle = (@low + @high) / 2
          ok, finding = probe(@merges[middle])
          ok ? @low = middle + 1 : fail_at(middle, finding)
        end

        # A failing merge is probed once more; passing the second time is flaky, not bad.
        def probe(merge)
          ok, finding = probe_once(merge)
          return [ok, finding] if ok

          again, = probe_once(merge)
          @flaky << merge[:sha] if again
          [again, finding]
        end

        def probe_once(merge)
          raise ConsoleCapture::Failure, "probe budget of #{@limit} spent" if @spent >= @limit

          @spent += 1
          @probe.call(merge).tap { |ok, _finding| @log << "#{merge[:sha].to_s[0, 10]} #{ok ? "green" : "red"}" }
        end

        def fail_at(middle, finding)
          @found = @merges[middle].merge(finding: finding || {})
          @high = middle - 1
        end
      end
    end
  end
end
