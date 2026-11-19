# frozen_string_literal: true

require_relative "../console_capture"
require_relative "searching"

module Hecks
  module Adapters
    class MainIntegration
      # The facts about a failed verification's range of landings that a rule about reverting
      # needs: the first merge whose own specs fail, whether those specs are red at the last
      # verified commit too, whether a landing of the range was already reverted, and whether the
      # merge reached `origin/main`. It reads and decides nothing; whether to revert is the
      # domain's rule. It runs outside any verification's copy, one probe after another.
      class Bisecting
        # What the merge's keys hold when no merge failed. `searched` is false until a search ran.
        NONE = { culprit: "", subject: "", branch: "", work: "", finding: "", spec: "", example: "", base_red: false,
                 local: false, searched: false }.freeze

        class << self
          # @return [Hash{String => Hash}] the facts of each search, by commit, so a refusal and the
          #   bisect that follows it search once
          def searches = (@searches ||= {})

          # Searches once per commit; a search that cannot run answers the reason, never raises.
          #
          # @return [Hash{Symbol => Object}] the facts of {#facts}, or `culprit: ""` and a `reason`
          def search(repository, landed, since, failing: [], runner: nil)
            searches.clear if searches.size > 20
            searches[landed] ||= new(repository, failing: failing, runner: runner).facts(landed, since)
          rescue StandardError, ConsoleCapture::Failure => e
            { culprit: "", searched: true, reason: "#{Searching::UNFOUND}: the search could not run: #{e.message}" }
          end

          # @param facts [Hash, nil] what {.search} answered; nil when no search was made
          # @param since [String] the commit the range starts after
          # @return [Hash{Symbol => Hash}] each fact as a `value:`, a missing one as for no merge
          def answer(facts, since)
            none = NONE.merge(base: since, already_reverted: false, reason: "the shallow check is on: no search was made")
            none.merge(facts || {}).transform_values { |fact| { value: fact } }
          end

          # @param facts [Hash] what {.search} answered
          # @return [String] the line a refusal carries
          def line(facts)
            return "no first bad merge: #{facts[:reason]}" if facts[:culprit].to_s.empty?

            "first bad merge #{facts[:culprit][0, 10]} #{facts[:subject]}#{detail(facts)}"
          end

          private

          def detail(facts)
            parts = [("spec #{facts[:spec]}" unless facts[:spec].to_s.empty?),
                     ("first failing example #{facts[:example]}" unless facts[:example].to_s.empty?),
                     ("red at #{facts[:base][0, 10]} too" if facts[:base_red])]
            parts.compact.map { |part| "; #{part}" }.join
          end
        end

        # @param repository [Repository] the repository the landings are in
        # @param failing [Array<String>] the spec files the failed verification named
        # @param runner [#call, nil] stands in for {SpecProbe}: given a copy's directory and the
        #   spec files, it returns, or raises `ConsoleCapture::Failure` when one is red
        def initialize(repository, failing: [], runner: nil)
          @search = Searching.new(repository, failing: failing, runner: runner)
        end

        # @param landed [String] the commit that failed verification
        # @param since [String] the last verified commit, or `origin/main`, the range starts after
        # @return [Hash{Symbol => Object}] `base`, `culprit`, `subject`, `branch`, `work`,
        #   `finding`, `spec`, `example`, `base_red`, `already_reverted`, `local`, `searched` and
        #   `reason`; the merge's keys are "" when none failed
        def facts(landed, since) = @search.call(landed, since)
      end
    end
  end
end
