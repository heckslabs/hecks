# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Hecks
  module Tools
    module RegenerationRun
      # The scratch crate of a `--check`: copies of the generated tree and Cargo.toml that a
      # projection writes into, and the comparison of what it wrote with the tree on disk. The
      # working tree is never written.
      module Scratch
        # The refusal when a check finds nothing generated to compare.
        NOT_MATERIALIZED = "hecks regenerate_corpus --check: rust/src/generated has no generated output to " \
                           "compare. Only pizzas, mod.rs and Cargo.toml are committed; run " \
                           "`hecks regenerate_corpus --confirm` first, then the check."

        # A scratch crate: copies of the generated tree and Cargo.toml, all `hecks project_rust`
        # writes.
        #
        # @param root [String] the checkout
        # @return [String] the scratch directory
        def scratch_crate(root)
          abort NOT_MATERIALIZED unless File.directory?(File.join(root, "rust/src/generated/meta"))

          scratch = Dir.mktmpdir("regen-codegen-check")
          FileUtils.mkdir_p(File.join(scratch, "src"))
          FileUtils.cp_r(File.join(root, "rust/src/generated"), File.join(scratch, "src/generated"))
          FileUtils.cp(File.join(root, "rust/Cargo.toml"), scratch)
          scratch
        end

        # The gate: the scratch projection must match the generated sources and Cargo.toml on disk.
        #
        # @param scratch [String] the scratch crate, removed here
        # @return [Integer] 0 when it matches, 1 after printing the difference
        def verdict(scratch)
          same = matches_scratch?(scratch)
          FileUtils.rm_rf(scratch)
          same ? 0 : 1
        end

        # @param scratch [String] the scratch crate
        # @return [Boolean] whether it matches the tree, printing `git diff` output when it does not
        def matches_scratch?(scratch)
          pairs = [["rust/src/generated", File.join(scratch, "src/generated")],
                   ["rust/Cargo.toml", File.join(scratch, "Cargo.toml")]]
          pairs.map do |on_disk, projected|
            out, status = Open3.capture2e("git", "diff", "--no-index", "--exit-code", "--", on_disk, projected)
            print out
            status.success?
          end.all?
        end
      end
    end
  end
end
