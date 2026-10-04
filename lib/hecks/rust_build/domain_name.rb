# frozen_string_literal: true

require "hecks/vocabulary"
require "hecks/bluebook/model_check"

module Hecks
  module RustBuild
    # Whether a domain's directory name can double as a Rust module identifier and a Cargo
    # feature name. The reserved-word half is `ModelCheck.rust_reserved_name_findings`, the one
    # shared check.
    module DomainName
      # Every key `rust/Cargo.toml` uses outside `[features]`, plus `default`, which Cargo
      # reserves for the auto-enabled feature set. Declared once as the `CargoReservedName`
      # vocabulary.
      CARGO_RESERVED = Hecks::Vocabulary.fetch("CargoReservedName")

      # @param name [String] the domain's directory name
      # @return [Boolean] whether it is a plain lowercase identifier and no reserved word
      def self.valid?(name)
        text = name.to_s
        text.match?(/\A[a-z_][a-z0-9_]*\z/) &&
          Hecks::Bluebook::ModelCheck.rust_reserved_name_findings(domain_name: text).empty?
      end
    end
  end
end
