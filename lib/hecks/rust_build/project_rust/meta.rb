# frozen_string_literal: true

require "fileutils"
require_relative "../../bluebook/meta_validator"

module Hecks
  module RustBuild
    class ProjectRust
      # The self-hosted language's Rust, `src/generated/meta`. It is generated from the grammar
      # registry alone, so it is the same whichever domain a run projects: a corpus run generates it
      # once here and tells each of its `hecks project_rust` children to skip it (`SKIP_FLAG`),
      # instead of every child writing the identical files again.
      module Meta
        # The flag telling a `hecks project_rust` run that `meta` is already generated.
        SKIP_FLAG = "--skip-meta"

        # @return [Hash] the self-hosted language's IR, shaped for `hecks-codegen`
        def self.ir
          bluebook = Hecks::Projector::Exporter.call(Hecks::Bluebook::MetaValidator.grammar_registry).fetch("Bluebook")
          TargetIr.json_shaped(bluebook)
        end

        # Generates `meta` into the workspace, writing only the files whose bytes changed.
        #
        # @param rust_dir [String] the workspace being generated into
        # @return [void]
        # @raise [Failure] when `hecks-codegen` cannot be built or exits non-zero
        def self.generate(rust_dir = RustBuild.rust_dir)
          out_root = File.join(rust_dir, "src/generated")
          FileUtils.mkdir_p(out_root)
          CodegenRun.new(rust_dir: rust_dir, out_root: out_root, meta: ir).call
        end
      end
    end
  end
end
