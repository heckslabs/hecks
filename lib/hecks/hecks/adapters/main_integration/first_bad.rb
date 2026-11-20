# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # The merge at which the red that stands at the end of a failed verification's range began:
      # the failing example is red there and green at its first parent. It walks back from the
      # newest merge while the example is red, and the merge after the first green one is the
      # candidate, so a break a later merge mended is never visited.
      #
      # The candidate is named only when a repeat run confirms each side: red at the merge twice,
      # green at its first parent twice. A side whose two runs disagree is reported in `flaky` and
      # nothing is named. Only those two commits are run twice: a flake at another merge is not
      # seen as one. A parent that does not hold the example reads green, so the merge that adds
      # a failing example is named. It reads facts and writes none; a probe that errors or a spent
      # budget answers nil with a `reason`, never an exception.
      class FirstBad
        # The most probes one search makes; each is a clean copy and a run of one example.
        LIMIT = 16

        # The probes kept back for the candidate: its repeat run and two runs of its first parent.
        CONFIRMING = 3

        # Why a search names no merge when the example is green at the newest one.
        NONE_RED = "no merge in the range turns the failing specs red"

        # @param merges [Array<Hash>] the landings, oldest first (`Repository#merges`)
        # @param probe [#call, #before] `call` given a merge answers `[ok, finding]` at the merge
        #   and `before` the same at its first parent; `finding` is a Hash with `:spec` and
        #   `:example` when it failed
        # @param limit [Integer] the most probes to make
        def initialize(merges, probe:, limit: LIMIT)
          @merges = merges
          @probe = probe
          @limit = limit
        end

        # @return [String] why the last search answered nil
        attr_reader :reason

        # @return [Array<String>] the commits whose two runs disagreed, a first parent as the
        #   merge's sha and `^`: reported as a fact, never blamed
        attr_reader :flaky

        # @return [Array<String>] each probe made, in order: the commit (a first parent as the
        #   merge and `^`) and whether the example was `green` or `red` there
        attr_reader :log

        # @return [Hash, nil] the merge (`sha:`, `subject:`, `paths:`) with its `finding:`, or nil
        #   when none is named or the search could not finish (`reason` says which)
        def call
          start
          candidate = standing_red
          candidate && confirmed(candidate)
        rescue StandardError, ConsoleCapture::Failure => e
          @reason = "the search stopped: #{e.message}"
          nil
        end

        private

        def start
          @spent = 0
          @flaky = []
          @log = []
          @findings = {}
          @reason = nil
        end

        # The oldest merge of the red run that reaches the newest merge.
        def standing_red
          index = @merges.size
          while index.positive?
            return over_budget(index) if @spent >= @limit - CONFIRMING
            break unless red?(@merges[index - 1])

            index -= 1
          end
          @merges[index] || unnamed(NONE_RED)
        end

        def red?(merge)
          ok, finding = run(:call, merge)
          @findings[merge[:sha]] = finding unless ok
          !ok
        end

        def confirmed(merge)
          return flips(merge[:sha]) if run(:call, merge).first

          green_before?(merge) && merge.merge(finding: @findings[merge[:sha]] || {})
        end

        # Whether both runs of the merge's first parent are green; else why nothing is named.
        def green_before?(merge)
          first, second = Array.new(2) { run(:before, merge).first }
          return flips(merge[:sha], "^") if first != second

          first || unnamed("#{merge[:sha][0, 10]} is red and so is its parent")
        end

        def run(side, merge)
          raise ConsoleCapture::Failure, "probe budget of #{@limit} spent" if @spent >= @limit

          @spent += 1
          at = "#{merge[:sha].to_s[0, 10]}#{"^" if side == :before}"
          @probe.public_send(side, merge).tap { |ok, _finding| @log << "#{at} #{ok ? "green" : "red"}" }
        end

        def flips(sha, parent = "")
          @flaky << "#{sha}#{parent}"
          unnamed("flaky: the failing example flips between two runs at #{sha[0, 10]}#{parent}")
        end

        def over_budget(index)
          from = @merges[index][:sha][0, 10]
          unnamed("the red run is longer than the probe budget of #{@limit}: red from #{from} to the newest merge")
        end

        def unnamed(why)
          @reason = why
          nil
        end
      end
    end
  end
end
