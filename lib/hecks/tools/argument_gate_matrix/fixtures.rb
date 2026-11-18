# frozen_string_literal: true

require "json"
require_relative "../../tools"

module Hecks
  module Tools
    module ArgumentGateMatrix
      # The Rust conformance fixtures of the matrix: one per domain, replaying that domain's kept
      # rows as steps, with the `expect` block `seed_semantics_corpus` freezes into it.
      module Fixtures
        # Writes one domain's fixture, keeping its frozen `expect` while the steps are unchanged.
        #
        # @param root [String] the checkout
        # @param domain [String] a domain directory, as listed in `DOMAINS`
        # @param rows [Array<Hash>] that domain's kept rows
        # @return [void]
        def write_fixture(root, domain, rows)
          path = File.join(root, fixture_path(domain))
          fixture = fixture_for(domain, rows)
          frozen = frozen_expect(path, fixture)
          fixture["expect"] = frozen if frozen
          File.write(path, "#{JSON.pretty_generate(fixture)}\n")
          puts frozen ? "wrote #{path}" : "wrote #{path} (#{RESEED})"
        end

        # What a fixture whose steps moved needs before the Rust conformance spec can read it.
        RESEED = "steps moved: seed its expect with test_suite_run.seed_semantics_corpus!"

        # The `expect` block `seed_semantics_corpus` froze into the committed fixture, kept while
        # the steps it was frozen from are the same; moved steps need it seeded again.
        #
        # @param path [String] the fixture's absolute path
        # @param fixture [Hash] the fixture about to be written
        # @return [Hash, nil] the block to keep, or nil when there is none or the steps moved
        def frozen_expect(path, fixture)
          return unless File.exist?(path)

          committed = JSON.parse(File.read(path))
          committed["expect"] if committed["steps"] == JSON.parse(JSON.generate(fixture["steps"]))
        end

        # @param domain [String] a domain directory, as listed in `DOMAINS`
        # @return [String] the Rust conformance fixture for that domain, relative to the checkout
        def fixture_path(domain) = "spec/corpus/rust_conformance/argument_gate_order_#{File.basename(domain)}.json"

        # @param domain [String] a domain directory, as listed in `DOMAINS`
        # @param rows [Array<Hash>] that domain's kept rows
        # @return [Hash] the fixture replaying those rows, without its `expect` block
        def fixture_for(domain, rows)
          { "domain" => domain, "note" => FIXTURE_NOTE, "steps" => rows.map { |row| fixture_step(row) } }
        end

        # @param row [Hash] one kept row
        # @return [Hash] the replay step for that row
        def fixture_step(row)
          step = { "verb" => row[:verb] }
          step["role"] = row[:role] if row[:role]
          step["args"] = row[:args]
          step
        end
      end
    end
  end
end
