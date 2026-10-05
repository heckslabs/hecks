# frozen_string_literal: true

require "fileutils"
require "open3"
require_relative "../rust_build"
require_relative "wasm"

module Hecks
  module RustBuild
    # Builds the Rust host binary for a domain and stages it with the domain's module and IR, the
    # three files a container image copies in.
    #
    #   Host.call(["path/to/domain", "--target=aarch64-unknown-linux-gnu", "--stage=build/host"])
    #
    # The host is compiled from the workspace this release carries (`rust/host`), so the binary is
    # the one the installed gem was released with; nothing is fetched. The module and IR come from
    # `Wasm`. `CARGO_TARGET_DIR` names where Cargo writes (the copy's `target/` for a client), so
    # a second build recompiles only what changed. Stages `<domain>-host`, `<domain>.wasm` and
    # `<domain>.ir.json` in `--stage` (default `.hecks/host/<target>/` in the working directory).
    module Host
      # The host crate's binary.
      BINARY = "bootstrap"

      # The toolchain Cargo runs under, as `Wasm` builds with.
      TOOLCHAIN = "stable"

      # A Rust target triple: `<arch>-<vendor>-<os>`, with an optional `-<env>`.
      TRIPLE = /\A[a-z0-9_]+(-[a-z0-9_.]+){2,3}\z/

      module_function

      # @param argv [Array<String>] the domain's directory, then optional `--target=<triple>` and
      #   `--stage=<directory>`
      # @return [Integer] the exit status
      # @raise [Failure] when the toolchain, the target or a step is missing or fails
      def call(argv)
        domain = argv.find { |arg| !arg.start_with?("--") } or
          raise Failure, "usage: hecks build_host <domain> [target=<triple>] [stage=<directory>]"
        target = flag(argv, "target") || host_triple
        require_buildable!(target)
        stage = flag(argv, "stage") || File.join(Dir.pwd, ".hecks", "host", target)

        status = Wasm.call([domain])
        raise Failure, "project_wasm failed for #{domain}" unless status.zero?

        binary = compile(target)
        publish(binary, File.basename(domain.chomp("/")), stage)
        0
      end

      # @param argv [Array<String>] a tool's arguments
      # @param name [String] a flag's name
      # @return [String, nil] the value of `--<name>=<value>`, nil when absent
      def flag(argv, name)
        argv.filter_map { |arg| arg.delete_prefix("--#{name}=") if arg.start_with?("--#{name}=") }.last
      end

      # @return [String] the triple the Rust toolchain builds for by default
      # @raise [Failure] when there is no Rust toolchain
      def host_triple
        require_rustup!
        query("rustup", "run", TOOLCHAIN, "rustc", "-vV").to_s[/^host: (\S+)/, 1] or
          raise Failure, "rustup has no #{TOOLCHAIN} toolchain. Install it once with:\n\n    " \
                         "rustup toolchain install #{TOOLCHAIN}\n\nthen re-run the build."
      end

      def require_buildable!(target)
        raise Failure, "#{target} is not a Rust target triple (for example aarch64-unknown-linux-gnu)" unless
          TRIPLE.match?(target)
        if target.start_with?("wasm")
          raise Failure, "the host is a server binary; #{target} is a wasm target. Build the module with " \
                         "build.build_wasm, or name a native target"
        end

        require_rustup!
        installed = query("rustup", "target", "list", "--installed", "--toolchain", TOOLCHAIN).to_s.split
        return if installed.include?(target) || target == host_triple

        raise Failure, <<~MSG
          #{target} isn't installed for the #{TOOLCHAIN} toolchain. Install it once with:

              rustup target add #{target} --toolchain #{TOOLCHAIN}

          then re-run the build.
        MSG
      end

      def require_rustup!
        return if query("rustup", "--version")

        raise Failure, "rustup isn't installed. Install the Rust toolchain from https://rustup.rs, " \
                       "then re-run the build."
      end

      # `rustup run`, not bare `cargo`, as `Wasm` does. A cross target links with the
      # `<arch>-linux-gnu-gcc` on PATH unless `CARGO_TARGET_<TRIPLE>_LINKER` already names a linker.
      def compile(target)
        host_dir = File.join(RustBuild.rust_dir, "host")
        target_dir = ENV.fetch("CARGO_TARGET_DIR", File.join(host_dir, "target"))
        puts "== cargo build --release --target #{target} --bin #{BINARY} (rust/host) =="
        env = { "CARGO_TARGET_DIR" => target_dir }.merge(linker_for(target))
        RustBuild.command!("rustup", "run", TOOLCHAIN, "cargo", "build", "--release", "--target", target,
                           "--bin", BINARY, chdir: host_dir, env: env)
        File.join(target_dir, target, "release", BINARY)
      rescue Failure => e
        raise Failure, "#{e.message}#{cross_hint(target)}"
      end

      def linker_for(target)
        variable = "CARGO_TARGET_#{target.upcase.tr('-.', '__')}_LINKER"
        return {} if ENV.key?(variable) || target == host_triple

        candidate = "#{target.split('-').first}-linux-gnu-gcc"
        target.end_with?("linux-gnu") && query(candidate, "--version") ? { variable => candidate } : {}
      end

      def cross_hint(target)
        return "" if target == host_triple

        "\n#{target} differs from this machine's #{host_triple}, so linking needs a linker for it: " \
          "put a cross compiler such as #{target.split('-').first}-linux-gnu-gcc on PATH, or set " \
          "CARGO_TARGET_#{target.upcase.tr('-.', '__')}_LINKER"
      end

      def publish(binary, name, stage)
        dist = File.join(RustBuild.rust_dir, "dist")
        files = { binary => "#{name}-host", File.join(dist, "#{name}.wasm") => "#{name}.wasm",
                  File.join(dist, "#{name}.ir.json") => "#{name}.ir.json" }
        files.each_key do |path|
          raise Failure, "the build left no #{path}" unless File.file?(path)
        end
        FileUtils.mkdir_p(stage)
        files.each { |from, to| FileUtils.cp(from, File.join(stage, to)) }
        File.chmod(0o755, File.join(stage, "#{name}-host"))
        puts "staged in #{stage}: #{files.values.join(', ')}"
      end

      # @return [String, nil] a program's combined output, nil when it is missing or fails
      def query(*command)
        out, status = Open3.capture2e(*command)
        status.success? ? out : nil
      rescue SystemCallError
        nil
      end
    end
  end
end
