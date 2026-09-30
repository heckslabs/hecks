# frozen_string_literal: true

require "fileutils"
require_relative "../rust_build"
require_relative "project_rust"

module Hecks
  module RustBuild
    # Regenerates a domain's Rust source and cross-compiles it to `wasm32-wasip1`
    # (docs/decisions/0012-wasm-via-wasi-stdio.md).
    #
    #   Wasm.call(["path/to/domain"])
    #
    # Writes `<workspace>/dist/<domain>.wasm`, run with
    # `wasmtime run rust/dist/<domain>.wasm < script.json`, and the domain's `ir.json` beside it,
    # which `rust/host` reads at runtime. `HECKS_RUST_DIR` names the workspace to build in and
    # `CARGO_TARGET_DIR` where build output goes, beside the workspace by default.
    module Wasm
      # The Cargo target the module is built for.
      TARGET = "wasm32-wasip1"

      module_function

      # @param argv [Array<String>] the domain's directory
      # @return [Integer] the exit status
      # @raise [Failure] when the target is not installed or a step fails
      def call(argv)
        domain = argv.first or raise Failure, "usage: bin/project_wasm <domain>"
        return build_with_rust(domain) if ENV["HECKS_PARSER"] == "rust" && ENV["HECKS_CODEGEN"] == "rust"

        require_target!
        rust_dir = RustBuild.rust_dir
        scratch = scratch_copy(rust_dir)
        puts "== regenerating #{scratch}/src/generated/ for #{domain} =="
        status = RustBuild.with_env("HECKS_RUST_DIR" => scratch) { ProjectRust.call([domain]) }
        raise Failure, "project_rust failed for #{domain}" unless status.zero?

        compile(scratch)
        publish(scratch, rust_dir, File.basename(domain))
        0
      end

      # With the Rust parser and codegen, `hecks-build` runs the same steps and writes the same
      # outputs.
      def build_with_rust(domain)
        build_dir = File.join(ROOT, "rust", "build")
        puts "== cargo build (hecks-build) =="
        RustBuild.command!("cargo", "build", chdir: build_dir)
        puts "== hecks-build #{domain} --wasm =="
        RustBuild.command!(File.join(build_dir, "target", "debug", "hecks-build"), domain, "--wasm")
        0
      end

      def require_target!
        return if system("rustup target list --installed 2>/dev/null | grep -qx #{TARGET}")

        raise Failure, <<~MSG
          #{TARGET} isn't installed for this toolchain. Install it once with:

              rustup target add #{TARGET}

          then re-run the build.
        MSG
      end

      # Built in a scratch copy because generating rewrites `Cargo.toml` and `src/generated/`,
      # which would dirty tracked files in a checkout.
      def scratch_copy(rust_dir, name = "project_wasm")
        scratch = if ENV.key?("HECKS_RUST_DIR")
                    File.join(rust_dir, "scratch", name)
                  else
                    File.join(ROOT, "tmp", name, "rust")
                  end
        FileUtils.rm_rf(scratch)
        FileUtils.mkdir_p(scratch)
        %w[Cargo.toml Cargo.lock src].each { |entry| FileUtils.cp_r(File.join(rust_dir, entry), scratch) }
        scratch
      end

      # `rustup run`, not bare `cargo`: a `cargo` earlier on PATH may never have seen
      # `rustup target add` and fail with "can't find crate for `std`".
      def compile(scratch)
        puts "== cargo build --release --target #{TARGET} =="
        target_dir = ENV.fetch("CARGO_TARGET_DIR", File.join(RustBuild.rust_dir, "target"))
        RustBuild.command!("rustup", "run", "stable", "cargo", "build", "--release", "--target", TARGET,
                           chdir: scratch, env: { "CARGO_TARGET_DIR" => target_dir })
      end

      def publish(scratch, rust_dir, name)
        dist = File.join(rust_dir, "dist")
        FileUtils.mkdir_p(dist)
        target_dir = ENV.fetch("CARGO_TARGET_DIR", File.join(rust_dir, "target"))
        out = File.join(dist, "#{name}.wasm")
        FileUtils.cp(File.join(target_dir, TARGET, "release", "rust.wasm"), out)
        puts "wrote #{out}"
        puts %(run it: wasmtime run #{out} < script.json)
        sidecar = File.join(scratch, "src", "generated", name, "ir.json")
        return unless File.exist?(sidecar)

        FileUtils.cp(sidecar, File.join(dist, "#{name}.ir.json"))
        puts "wrote #{File.join(dist, "#{name}.ir.json")}"
      end
    end
  end
end
