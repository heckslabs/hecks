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
                           "compare. It is committed: restore it from git, or run " \
                           "`hecks regenerate_corpus --confirm`, then the check."

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

        # Puts back, in the scratch crate, every module the named domains do not own, as the tree
        # has it: a run of some domains rewrites the shared chapters and the grammar as its own last
        # writer would, which is not what the whole corpus's last writer left in the tree.
        #
        # @param scratch [String] the scratch crate
        # @param root [String] the checkout
        # @param owned [Array<String>] the features of the domains that ran
        # @return [void]
        def restore_shared(scratch, root, owned)
          source = File.join(root, "rust/src/generated")
          Dir.children(source).each do |entry|
            next if owned.include?(entry) || !File.directory?(File.join(source, entry))

            FileUtils.rm_rf(File.join(scratch, "src/generated", entry))
            FileUtils.cp_r(File.join(source, entry), File.join(scratch, "src/generated"))
          end
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
