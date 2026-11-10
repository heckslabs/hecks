# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # The Cargo a command of an integration step finds: rustup's proxies, ahead of any other
      # `cargo` on the caller's `PATH`, so the toolchain `rust/rust-toolchain.toml` pins is the
      # one that builds. A `cargo` installed beside rustup (Homebrew's) ignores that file and
      # builds with whatever version it is.
      module Toolchain
        module_function

        # @param base [#[]] the environment the command would otherwise inherit
        # @return [Hash{String => String}] `PATH` with rustup's proxy directory first; empty when
        #   this machine has no rustup `cargo`
        def environment(base = ENV)
          dir = proxies(base)
          return {} unless File.executable?(File.join(dir, "cargo"))

          rest = base.fetch("PATH", "").split(File::PATH_SEPARATOR) - [dir]
          { "PATH" => [dir, *rest].join(File::PATH_SEPARATOR) }
        end

        # @param base [#[]] the environment the command would otherwise inherit
        # @return [String] rustup's proxy directory: `$CARGO_HOME/bin`, else `~/.cargo/bin`
        def proxies(base = ENV) = File.join(base["CARGO_HOME"] || File.join(Dir.home, ".cargo"), "bin")
      end
    end
  end
end
