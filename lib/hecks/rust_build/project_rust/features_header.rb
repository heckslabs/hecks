# frozen_string_literal: true

module Hecks
  module RustBuild
    class ProjectRust
      # What a Cargo manifest with no `[features]` table is given in front of its text.
      FEATURES_HEADER = <<~TOML
        # One feature per generated domain: it selects which domain's own
        # generated::<domain>::merged module `generated::active` re-exports
        # (rust/src/generated/mod.rs). `hecks project_rust` adds a feature when a new domain is
        # generated and never removes one (the domain's own generated/<name>/ directory is the
        # source of truth for whether it exists). `default` tracks the domain generated most
        # recently, so a bare `cargo build` keeps working; any other still-generated domain stays
        # reachable via `--no-default-features --features <name>`.
        [features]
        default = []

      TOML
      private_constant :FEATURES_HEADER
    end
  end
end
