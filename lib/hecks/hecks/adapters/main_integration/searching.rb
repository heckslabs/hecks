# frozen_string_literal: true

require_relative "first_bad"
require_relative "merge_probe"

module Hecks
  module Adapters
    class MainIntegration
      # One search of a failed verification's range of landings: the first merge at which the
      # failing specs are red, whether they are red at the last verified commit too, and whether
      # that merge was already reverted in the range. A merge is named only when the specs are red
      # at it and green at its first parent. It reads and decides nothing.
      class Searching
        # The branch a landing's merge subject names.
        BRANCH = %r{\AMerge (?:branch '([^']+)'|pull request #\d+ from \S+?/(\S+))}

        # The suffix a retry or step branch adds to its Work item's key.
        WORK_SUFFIX = /-(?:step|r)\d+\z/

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
          reverts = @repository.reverts(since, landed)
          found = @failing.empty? ? unnamed : probed(@repository.merges(since, landed), since)
          undone = reverted?(found[:culprit].to_s, reverts, @repository.reverted(since, landed))
          { base: since }.merge(found, searched: true, already_reverted: undone)
        end

        private

        def unnamed = Bisecting::NONE.merge(reason: "#{UNFOUND}: the failed verification names no failing spec")

        # A revert that undid the merge found stands in the range; with no merge found, any revert.
        def reverted?(culprit, reverts, undone)
          culprit.empty? ? !reverts.empty? : undone.any? { |sha| culprit.start_with?(sha) }
        end

        def probed(merges, since)
          search = FirstBad.new(merges, probe: @probe)
          found = search.call
          base_red = @probe.red_at?(since)
          return Bisecting::NONE.merge(base_red: base_red, reason: unfound(search, base_red)) unless found
          return merge_facts(found, base_red, search.log) if base_red || !parent_red?(found, merges, since)

          Bisecting::NONE.merge(base_red: false, reason: "#{UNFOUND}: #{found[:sha][0, 10]} is red and so is its parent")
        end

        def unfound(search, base_red) = base_red ? search.reason.to_s : "#{UNFOUND}: #{search.reason}"

        # Whether the failing specs are red at the first parent of the merge found. The landing
        # before it in the range was probed green by the search and the range's base is `base_red`,
        # so only a first parent that is neither is probed here.
        def parent_red?(found, merges, since)
          parent = @repository.first_parent(found[:sha])
          index = merges.index { |merge| merge[:sha] == found[:sha] }
          known = @repository.commit(index.zero? ? since : merges[index - 1][:sha])
          !parent.nil? && parent != known && @probe.red_at?(parent)
        end

        def merge_facts(found, base_red, log)
          naming(found).merge(finding_facts(found, found[:finding] || {}, log))
                       .merge(base_red: base_red, local: !@repository.ancestor?(found[:sha], @repository.remote_main))
        end

        def naming(found)
          branch = branch_of(found[:subject])
          { culprit: found[:sha], parent: @repository.first_parent(found[:sha]).to_s, subject: found[:subject],
            branch: branch, work: branch.sub(WORK_SUFFIX, "") }
        end

        def finding_facts(found, finding, log)
          { finding: finding_line(found, finding, log), spec: finding[:spec].to_s, example: finding[:example].to_s }
        end

        # What a reopened Work item's detail says of the merge: what it broke and each probe the
        # search made. The revert's report adds the revert commit and how the work lands again.
        def finding_line(found, finding, log)
          parts = ["culprit #{found[:sha]} #{found[:subject]}", ("spec #{finding[:spec]}" unless finding[:spec].to_s.empty?),
                   ("first failing example #{finding[:example]}" unless finding[:example].to_s.empty?),
                   ("search: #{log.join(", ")}" unless log.empty?)]
          "A red main reverted this merge: #{parts.compact.join("; ")}."
        end

        def branch_of(subject)
          match = BRANCH.match(subject.to_s)
          match ? match.captures.compact.first : ""
        end
      end
    end
  end
end
