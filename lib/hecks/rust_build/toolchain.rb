# frozen_string_literal: true

module Hecks
  module RustBuild
    # The Cargo a build child finds: rustup's proxies ahead of any other `cargo` on the caller's
    # `PATH`, so the toolchain `rust-toolchain.toml` pins is the one that builds. A `cargo`
    # installed beside rustup (Homebrew's) ignores that file and builds with whatever version it is,
    # and a process started by launchd or a non-interactive shell often finds it first.
    module Toolchain
      # The `channel = "…"` line of a `rust-toolchain.toml`, capturing the channel.
      CHANNEL_LINE = /^\s*channel\s*=\s*"([^"]+)"/

      # What rustc prints when the compiler is older than the source needs.
      TOO_OLD = /error\[E0658\]|requires rustc|rustc \d+\.\d+(?:\.\d+)? is not supported/

      # The version `cargo --version` prints.
      VERSION_LINE = /cargo (\d+\.\d+(?:\.\d+)?)/

      module_function

      # @param base [#[]] the environment the command would otherwise inherit
      # @return [Hash{String => String}] `PATH` with rustup's proxy directory first; empty when the
      #   base names no `PATH` or this machine has no rustup `cargo`
      def environment(base = ENV)
        dir = proxies(base)
        return {} unless base["PATH"] && File.executable?(File.join(dir, "cargo"))

        rest = base["PATH"].split(File::PATH_SEPARATOR) - [dir]
        { "PATH" => [dir, *rest].join(File::PATH_SEPARATOR) }
      end

      # @param base [#[]] the environment the command would otherwise inherit
      # @return [String] rustup's proxy directory: `$CARGO_HOME/bin`, else `~/.cargo/bin`
      def proxies(base = ENV) = File.join(base["CARGO_HOME"] || File.join(Dir.home, ".cargo"), "bin")

      # @param root [String] a hecks checkout
      # @return [String, nil] the channel its `rust-toolchain.toml` pins, nil when it pins none
      def pinned(root)
        file = File.join(root, "rust-toolchain.toml")
        File.file?(file) ? File.read(file)[CHANNEL_LINE, 1] : nil
      end

      # Says why a failed build failed when the cause is a `cargo` older than the pin.
      #
      # @param output [String] what the build printed
      # @param root [String] the checkout built
      # @param env [Hash{String => String}] the variables the child ran with, over the process's
      # @return [String, nil] a message naming the cargo path and version, nil when the output
      #   does not show a toolchain too old for the source
      def failure(output, root:, env: {})
        return nil unless output.match?(TOO_OLD)

        found = cargo(ENV.to_h.merge(env))
        pin = pinned(root)
        return nil unless found && pin && older?(found[:version], pin)

        "toolchain failure: #{found[:path]} is #{found[:version]}, older than the #{pin} that " \
          "rust-toolchain.toml pins; put #{proxies(env)} before it on PATH"
      end

      # @param env [#[]] the environment a build ran with
      # @return [Hash, nil] the first `cargo` on its `PATH`: `:path` and `:version`
      def cargo(env)
        path = first_cargo(env["PATH"].to_s)
        version = path && IO.popen([path, "--version"], err: File::NULL, &:read)[VERSION_LINE, 1]
        version ? { path: path, version: version } : nil
      rescue SystemCallError
        nil
      end

      # @param search [String] a `PATH`
      # @return [String, nil] the first executable `cargo` along it
      def first_cargo(search)
        files = search.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "cargo") }
        files.find { |file| File.executable?(file) }
      end

      # @return [Boolean] whether version +known+ is older than version +wanted+
      def older?(known, wanted) = Gem::Version.new(known) < Gem::Version.new(wanted)
    end
  end
end
