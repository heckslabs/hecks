# frozen_string_literal: true

require_relative "first_bad"
require_relative "merge_probe"

module Hecks
  module Adapters
    class MainIntegration
      # One search of a failed verification's range of landings: the first merge at which the
      # failing specs are red, whether they are red at the last verified commit too, and whether a
      # landing of the range was already reverted. It reads and decides nothing.
      class Searching
        # The branch a landing's merge subject names.
        BRANCH = %r{\AMerge (?:branch '([^']+)'|pull request #\d+ from \S+?/(\S+))}

        # What the owner reads when the search ends with no merge and the base is green.
        UNFOUND = "main is red and no single merge was found"

        # @param repository [Repository] the repository the landings are in
        # @param failing [Array<String>] the spec files the failed verification named
        # @param runner [#call, nil] stands in for {SpecProbe}
        def initialize(repository, failing:, runner: nil)
          @repository = repository
          @failing = failing
          @probe = MergeProbe.new(repository, failing: failing, runner: runner)
        end

        # @param landed [String] the commit that failed verification
        # @param since [String] the commit the range starts after
        # @return [Hash{Symbol => Object}] the facts of {Bisecting#facts}
        def call(landed, since)
          facts = { base: since, already_reverted: !@repository.reverts(since, landed).empty? }
          facts.merge(@failing.empty? ? unnamed : probed(@repository.merges(since, landed), since), searched: true)
        end

        private

        def unnamed = Bisecting::NONE.merge(reason: "#{UNFOUND}: the failed verification names no failing spec")

        def probed(merges, since)
          search = FirstBad.new(merges, probe: @probe)
          found = search.call
          base_red = @probe.red_at?(since)
          found ? merge_facts(found, base_red) : Bisecting::NONE.merge(base_red: base_red, reason: unfound(search, base_red))
        end

        def unfound(search, base_red) = base_red ? search.reason.to_s : "#{UNFOUND}: #{search.reason}"

        def merge_facts(found, base_red)
          finding = found[:finding] || {}
          { culprit: found[:sha], subject: found[:subject], branch: branch_of(found[:subject]),
            spec: finding[:spec].to_s, example: finding[:example].to_s, base_red: base_red,
            local: !@repository.ancestor?(found[:sha], @repository.remote_main) }
        end

        def branch_of(subject)
          match = BRANCH.match(subject.to_s)
          match ? match.captures.compact.first : ""
        end
      end
    end
  end
end
