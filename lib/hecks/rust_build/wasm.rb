# frozen_string_literal: true

require "fileutils"
require_relative "../rust_build"
require_relative "project_rust"
require_relative "command_schemas"

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
    # `--profile=dev` builds without `--release`: a much faster compile, for tests that
    # only run the module, not for one that ships.
    module Wasm
      # The Cargo target the module is built for.
      TARGET = "wasm32-wasip1"

      # The Cargo flags and the `target/<target>/` directory of each build profile.
      PROFILES = { "release" => { flags: ["--release"], dir: "release" }, "dev" => { flags: [], dir: "debug" } }.freeze

      module_function

      # @param argv [Array<String>] the domain's directory, then an optional `--profile=release|dev`
      # @return [Integer] the exit status
      # @raise [Failure] when the target is not installed, the profile is unknown or a step fails
      def call(argv)
        domain = argv.find { |arg| !arg.start_with?("--") } or raise Failure, "usage: hecks build_wasm <domain>"
        name = profile_name(argv)
        profile(name)

        require_target!
        rust_dir = RustBuild.rust_dir
        scratch = scratch_copy(rust_dir)
        regenerate(scratch, domain)
        compile(scratch, name)
        publish(scratch, rust_dir, File.basename(domain), name)
        0
      end

      # @param argv [Array<String>] the tool's arguments
      # @return [String] the `--profile=<name>` value, `release` when none is named
      def profile_name(argv)
        argv.filter_map { |arg| arg.delete_prefix("--profile=") if arg.start_with?("--profile=") }.last || "release"
      end

      def regenerate(scratch, domain)
        puts "== regenerating #{scratch}/src/generated/ for #{domain} =="
        status = RustBuild.in_workspace(scratch) { ProjectRust.call([domain]) }
        raise Failure, "project_rust failed for #{domain}" unless status.zero?

        write_schemas(scratch, domain)
      end

      # The command schemas go into the scratch copy only: they are a build output for the host to
      # serve, not part of the generated corpus the drift check holds to the tree.
      def write_schemas(scratch, domain)
        loader = ProjectRust::DomainLoader.new(domain).call
        CommandSchemas.write(loader.registry.bluebook(loader.domain_name),
                             File.join(scratch, "src", "generated", File.basename(domain)))
      end

      def require_target!
        return if RustBuild.target_installed?(TARGET)

        raise Failure, <<~MSG
          #{TARGET} isn't installed for this toolchain. Install it once with:

              rustup target add #{TARGET}

          then re-run the build.
        MSG
      end

      # Built in a scratch copy because generating rewrites `Cargo.toml` and `src/generated/`,
      # which would dirty tracked files in a checkout.
      def scratch_copy(rust_dir, name = "project_wasm")
        scratch = if RustBuild.explicit_workspace?
                    File.join(rust_dir, "scratch", name)
                  else
                    File.join(ROOT, "tmp", name, "rust")
                  end
        FileUtils.rm_rf(scratch)
        FileUtils.mkdir_p(scratch)
        %w[Cargo.toml Cargo.lock src expr].each { |entry| FileUtils.cp_r(File.join(rust_dir, entry), scratch) }
        scratch
      end

      # `rustup run`, not bare `cargo`: a `cargo` earlier on PATH may never have seen
      # `rustup target add` and fail with "can't find crate for `std`".
      def compile(scratch, profile_name = "release")
        flags = profile(profile_name).fetch(:flags)
        puts "== cargo build #{flags.join(" ")} --target #{TARGET} =="
        target_dir = ENV.fetch("CARGO_TARGET_DIR", File.join(RustBuild.rust_dir, "target"))
        RustBuild.command!("rustup", "run", "stable", "cargo", "build", *flags, "--target", TARGET,
                           chdir: scratch, env: { "CARGO_TARGET_DIR" => target_dir })
      end

      # @param name [String] `release` or `dev`
      # @return [Hash] the flags and directory of the profile
      # @raise [Failure] when the name is not `release` or `dev`
      def profile(name = "release")
        PROFILES.fetch(name) { raise Failure, "--profile=#{name} is not release or dev" }
      end

      def publish(scratch, rust_dir, name, profile_name = "release")
        dist = File.join(rust_dir, "dist")
        FileUtils.mkdir_p(dist)
        target_dir = ENV.fetch("CARGO_TARGET_DIR", File.join(rust_dir, "target"))
        out = File.join(dist, "#{name}.wasm")
        FileUtils.cp(File.join(target_dir, TARGET, profile(profile_name).fetch(:dir), "rust.wasm"), out)
        puts "wrote #{out}"
        puts %(run it: wasmtime run #{out} < script.json)
        publish_sidecar(scratch, dist, name)
      end

      def publish_sidecar(scratch, dist, name)
        sidecar = File.join(scratch, "src", "generated", name, "ir.json")
        return unless File.exist?(sidecar)

        FileUtils.cp(sidecar, File.join(dist, "#{name}.ir.json"))
        puts "wrote #{File.join(dist, "#{name}.ir.json")}"
        publish_schemas(scratch, dist, name)
      end

      # The command schemas beside the IR, which the host serves at a command's `?schema=1`.
      def publish_schemas(scratch, dist, name)
        schemas = File.join(scratch, "src", "generated", name, "schemas.json")
        return unless File.exist?(schemas)

        FileUtils.cp(schemas, File.join(dist, "#{name}.schemas.json"))
        puts "wrote #{File.join(dist, "#{name}.schemas.json")}"
      end
    end
  end
end
