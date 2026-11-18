# frozen_string_literal: true

require_relative "../../../rust_build/toolchain"

module Hecks
  module Adapters
    class MainIntegration
      # The Cargo a command of an integration step finds: rustup's proxies, ahead of any other
      # `cargo` on the caller's `PATH`; the module every Rust build child shares.
      Toolchain = RustBuild::Toolchain
    end
  end
end
