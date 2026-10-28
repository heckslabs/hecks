# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../write_if_changed"

module Hecks
  module RustBuild
    class ProjectRust
      # Generates a domain's Rust by running `hecks-codegen full` on IR the caller built from the
      # live registry, into a scratch directory, then copies only the files whose bytes changed
      # into `src/generated/`. An unchanged file keeps its mtime, so Cargo does not rebuild.
      class CodegenRun
        META_LABEL = "the self-hosted language (lib/hecks/language/bluebook)"

        # One bluebook's IR, generated into its own module.
        Declaration = Struct.new(:mod_name, :label, :ir)

        # The `hecks-codegen` crate: the workspace's own copy when it carries one (a packaged
        # workspace does), otherwise the checkout's, so a scratch crate holding only the generated
        # tree still finds it.
        #
        # @param rust_dir [String] the workspace being generated into
        # @return [String] the crate's directory
        def self.crate_dir(rust_dir)
          own = File.join(rust_dir, "codegen")
          File.directory?(own) ? own : File.join(RustBuild::ROOT, "rust/codegen")
        end

        # Where Cargo puts the binary: under `CARGO_TARGET_DIR` when a build sets it (a copy of the
        # packaged workspace does, so nothing is written into the installed gem), else in the crate.
        #
        # @param rust_dir [String] the workspace being generated into
        # @param env [#fetch] the environment Cargo will run with
        # @return [String] the binary's path
        def self.binary(rust_dir, env: ENV)
          target = env.fetch("CARGO_TARGET_DIR") { File.join(crate_dir(rust_dir), "target") }
          File.join(target, "debug/hecks-codegen")
        end

        # @param rust_dir [String] the workspace being generated into
        # @param out_root [String] the crate's `src/generated`
        # @param target [Declaration, nil] the domain being projected; nil for a run of `meta` alone
        # @param declarations [Array<Declaration>] every other bluebook the target attached
        # @param meta [Hash, nil] the self-hosted language's IR; nil leaves `meta` as it is on disk
        def initialize(rust_dir:, out_root:, meta: nil, target: nil, declarations: [])
          @rust_dir = rust_dir
          @out_root = out_root
          @target = target
          @declarations = declarations
          @meta = meta
        end

        # @return [void]
        # @raise [Failure] when `hecks-codegen` cannot be built or exits non-zero
        def call
          build_binary
          Dir.mktmpdir("hecks-codegen-full") do |tmp|
            stage = File.join(tmp, "generated")
            FileUtils.mkdir_p(stage)
            generate_meta(stage, tmp) if @meta
            generate_target(stage, tmp) if @target
            sync(stage)
          end
        end

        # Builds the binary once, then holds the build as done while the block runs. Each `cargo
        # build` replaces the binary with a fresh link, so children forked to generate side by side
        # would each leave a moment when a sibling finds no binary to start; the parent builds
        # instead, before the fork, and the children skip it.
        #
        # @param rust_dir [String] the workspace being generated into
        # @yield the work that forks the children
        # @return [Object] the block's value
        # @raise [Failure] when `hecks-codegen` cannot be built
        def self.prebuilt(rust_dir)
          dir = crate_dir(rust_dir)
          build(dir)
          @prebuilt = dir
          yield
        ensure
          @prebuilt = nil
        end

        # @param dir [String] the `hecks-codegen` crate's directory
        # @return [Boolean] whether a parent process built it for the children it forked
        def self.prebuilt?(dir) = @prebuilt == dir

        # @param dir [String] the `hecks-codegen` crate's directory
        # @return [void]
        # @raise [Failure] when Cargo cannot build it
        def self.build(dir)
          output, status = Open3.capture2e("cargo", "build", "--quiet", chdir: dir)
          $stdout.write(output)
          return if status.success?

          raise Failure, "hecks project_rust: cargo build failed in #{dir} — run it there directly to see why"
        end

        private

        def build_binary
          dir = self.class.crate_dir(@rust_dir)
          self.class.build(dir) unless self.class.prebuilt?(dir)
        end

        def generate_meta(stage, tmp)
          ir_path = write_ir(tmp, "meta", @meta)
          run("full", stage, "meta", META_LABEL, ir_path)
        end

        def generate_target(stage, tmp)
          args = [stage, @target.mod_name, @target.label, write_ir(tmp, @target.mod_name, @target.ir)]
          @declarations.each do |declaration|
            args.push(declaration.mod_name, declaration.label, write_ir(tmp, declaration.mod_name, declaration.ir))
          end
          run("full", *args)
        end

        def write_ir(tmp, name, tree)
          path = File.join(tmp, "#{name}_ir.json")
          File.write(path, JSON.pretty_generate(tree))
          path
        end

        def run(*args)
          return if system(self.class.binary(@rust_dir), *args, out: $stdout, err: $stderr)

          raise Failure, "hecks project_rust: hecks-codegen #{args.first} failed"
        end

        # Each module directory is tracked, so a file an earlier run wrote and this one did not
        # (a removed aggregate) is pruned. Pruning waits for the whole copy to succeed: after a
        # failure, the files not yet reached would look like orphans and be deleted.
        def sync(stage)
          Dir.children(stage).sort.each do |name|
            source = File.join(stage, name)
            dest = File.join(@out_root, name)
            WriteIfChanged.push_directory(dest)
            copy_changed(source, dest)
            WriteIfChanged.pop_and_prune(dest)
          end
        end

        def copy_changed(source, dest)
          texts = Dir.children(source).sort.to_h do |file|
            [File.join(dest, file), File.read(File.join(source, file), encoding: "UTF-8")]
          end
          RustFormat.files(texts).each do |path, text|
            wrote = WriteIfChanged.call(path, text, formatted: true, atomic: true)
            puts(wrote ? "wrote #{path}" : "#{path} unchanged")
          end
        end
      end
    end
  end
end
