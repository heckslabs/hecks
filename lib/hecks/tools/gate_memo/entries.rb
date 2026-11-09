# frozen_string_literal: true

module Hecks
  module Tools
    module GateMemo
      # The runs the memo keeps for one check. A check keeps its newest green run and up to three
      # earlier ones under `previous`, so checkouts on different trees that take turns at the same
      # check each find their own run instead of replacing the other's.
      module Entries
        # How many green runs of one check the memo keeps.
        KEPT_RUNS = 4

        # @param entry [Hash, nil] the memo's entry for a check
        # @return [Array<Hash>] the runs it holds, newest first, each without its `previous`
        def runs(entry)
          return [] unless entry.is_a?(Hash)

          [entry.except("previous"), *Array(entry["previous"]).grep(Hash)]
        end

        # @param entry [Hash, nil] the memo's entry for a check
        # @param inputs [String, nil] the check's digest now
        # @return [Hash, nil] the green run on exactly these inputs, or nil
        def reused(entry, inputs)
          return nil if inputs.nil?

          runs(entry).find { |run| run["result"] == "green" && run["inputs"] == inputs }
        end

        # @param entry [Hash, nil] the memo's entry for a check
        # @param inputs [String, nil] the check's digest now
        # @return [Boolean] whether the entry holds a green run on exactly these inputs
        def reusable?(entry, inputs) = !reused(entry, inputs).nil?

        # Keeps a green run as the newest, behind which the check's earlier runs stay.
        #
        # @param memo [Hash] the memo, changed in place
        # @param id [String] a check id
        # @param entry [Hash] the green run to keep
        # @return [Hash] the entry now kept
        def remember(memo, id, entry)
          older = runs(memo[id]).reject { |run| run["inputs"] == entry["inputs"] }.first(KEPT_RUNS - 1)
          memo[id] = older.empty? ? entry : entry.merge("previous" => older)
        end

        # Forgets the runs on these inputs, which a red result has proved wrong, and leaves the
        # runs on other trees.
        #
        # @param memo [Hash] the memo, changed in place
        # @param id [String] a check id
        # @param inputs [String, nil] the digest of the red run; nil forgets every run of the check
        # @return [void]
        def forget(memo, id, inputs)
          kept = inputs ? runs(memo[id]).reject { |run| run["inputs"] == inputs } : []
          return memo.delete(id) if kept.empty?

          memo[id] = kept.drop(1).empty? ? kept.first : kept.first.merge("previous" => kept.drop(1))
        end
      end
    end
  end
end
