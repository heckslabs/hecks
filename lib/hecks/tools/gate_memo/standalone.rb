# frozen_string_literal: true

require_relative "../gate_memo"

module Hecks
  module Tools
    module GateMemo
      # The gate's memo, read by a check that is also run by hand. A green run of the check, in the
      # gate or alone, is kept with the digest of the files it read (`tree`); the check is skipped
      # when it is asked again on that same tree. Only a check that changes nothing asks: a run that
      # confirms, rewrites or names a part of the corpus never skips.
      module Standalone
        module_function

        # @param id [String] a check id
        # @return [String] the memo key a run by hand keeps its own green result under, so it never
        #   replaces the gate's entry for the check
        def key(id) = "standalone:#{id}"

        # @param root [String] the checkout
        # @param id [String] a check id with declared inputs in `GateMemo::INPUTS`
        # @param file [String] the memo's file
        # @return [String, nil] when the gate or a run by hand last passed the check on exactly
        #   these files; nil to run it
        def passed_at(root, id, file: GateMemo.path, tree: GateMemo.tree(root, id))
          memo, problem = GateMemo.read(file)
          return nil if problem || tree.nil?

          entries = [memo[id], memo[key(id)]].select { |e| e.is_a?(Hash) && e["result"] == "green" }
          entries.find { |entry| entry["tree"] == tree }&.fetch("at")
        end

        # @param root [String] the checkout
        # @param id [String] a check id with declared inputs
        # @param file [String] the memo's file
        # @return [void] keeps a green entry for the check on the files it read now; an unreadable
        #   memo is left as it is
        def record(root, id, file: GateMemo.path, tree: GateMemo.tree(root, id))
          memo, problem = GateMemo.read(file)
          return if problem || tree.nil?

          memo[key(id)] = GateMemo.green(tree, tree)
          GateMemo.write(memo, file)
        end

        # Runs the block unless the check already passed on these files, and keeps its pass. The
        # files are read before the block runs, so an edit made while it runs is not credited to it.
        #
        # @param root [String] the checkout
        # @param id [String] a check id with declared inputs
        # @param file [String] the memo's file
        # @return [String, Object] the skip line, or what the block returned when it did not raise
        def guard(root, id, file: GateMemo.path)
          tree = GateMemo.tree(root, id)
          at = passed_at(root, id, file: file, tree: tree)
          return skipped_line(at) if at

          yield.tap { record(root, id, file: file, tree: tree) }
        end

        # @param at [String] when the green run was recorded
        # @return [String] what a skipped check says
        def skipped_line(at) = "skipped as unchanged since #{at}"
      end
    end
  end
end
