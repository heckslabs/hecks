# frozen_string_literal: true

require "json"
require_relative "../../hecks"
require_relative "../fuzzing"

module Hecks
  module CLI
    # The command behind `bin/seed_semantics_corpus`: seeds (or deliberately re-seeds) the
    # `expect` block of semantics-corpus fixtures from the Ruby runtime. Review the result
    # against `docs/semantics/bluebook-semantics.md` before committing.
    #
    #   bin/seed_semantics_corpus                                # fill fixtures missing an expect
    #   SEED=refusal_kind_lifecycle bin/seed_semantics_corpus    # re-seed one, deliberately
    #
    # The seeded expectation is the definition, not a recording: both runtimes are compared to it.
    # `occurred_at` is stripped from events (C7.3/C9.1); refusals keep verb, error and kind (C8.2).
    module SeedSemanticsCorpus
      module_function

      # Seeds the fixtures that need it and reports which.
      #
      # @param root [String] the checkout whose `spec/corpus/semantics/` is seeded
      # @param env [Hash{String => String}] `SEED` names the one fixture to re-seed
      # @param out [IO] where the report goes
      # @return [Integer] the exit status, always 0
      def call(root:, env: ENV, out: $stdout)
        only = env.fetch("SEED", nil)
        seeded = Dir.glob(File.join(root, "spec/corpus/semantics", "*.json")).filter_map do |path|
          fixture = JSON.parse(File.read(path))
          name = File.basename(path, ".json")
          next if only ? only != name : fixture.key?("expect")

          fixture["expect"] = expectation_for(root, fixture)
          File.write(path, "#{JSON.pretty_generate(fixture)}\n")
          name
        end
        report(out, seeded)
        0
      end

      # Replays the fixture's script against the Ruby runtime. Each refusal's `"kind"` is reduced
      # to its class name; `occurred_at` is stripped from events.
      #
      # @param root [String] the checkout the fixture's domain path is relative to
      # @param fixture [Hash] the parsed fixture: `domain` and `steps`
      # @return [Hash{String => Array}] its `"expect"` block: refusals, instances, events
      def expectation_for(root, fixture)
        result = Hecks::Fuzzing::Replay.call(File.join(root, fixture["domain"]), fixture["steps"])
        {
          "refusals"  => JSON.parse(JSON.generate(result[:refusals])).each { |r| r["kind"] = r["kind"]&.split("::")&.last },
          "instances" => JSON.parse(JSON.generate(result[:instances])),
          "events"    => JSON.parse(JSON.generate(result[:events])).each { |e| e.delete("occurred_at") }
        }
      end

      # @param out [IO] where the report goes
      # @param seeded [Array<String>] the fixtures written
      # @return [void]
      def report(out, seeded)
        if seeded.empty?
          out.puts "nothing to seed - every fixture carries its expect (pass SEED=<name> to re-seed one deliberately)"
        else
          out.puts "seeded: #{seeded.join(', ')}"
          out.puts "review each expect against docs/semantics/bluebook-semantics.md before committing - " \
                   "it is the definition now"
        end
      end
    end
  end
end
