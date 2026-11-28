# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "hecks/harness/roles"
require_relative "hecks_harness_binary"

# The crew the Crew specs bring up. The checkout is a fixture, spec/fixtures/harness_roles. Each
# role's child plays the crew member's tape (rust/harness/tests/tapes), copied under the role's
# name, and the crew is stopped after one turn of every session, so no model runs.
module HecksCrewWorld
  TAPE = File.join(HecksHarnessBinary::DIR, "tests/tapes/crew_member.jsonl")
  CHECKOUT = File.expand_path("../fixtures/harness_roles", __dir__)

  module_function

  # @param roles [Array<String>] the roles given a tape
  # @return [String] a new directory holding the crew member's tape once for each role
  def tapes(roles)
    Dir.mktmpdir("crew-tapes").tap do |dir|
      roles.each { |role| FileUtils.cp(TAPE, File.join(dir, "#{role}.jsonl")) }
    end
  end

  # @return [Array<String>] the roles brought up
  def crew = Hecks::Harness::Roles.crew(root: CHECKOUT)

  # Brings the crew up through the command, as the Maintainer, in a booted Hecks.
  #
  # @return [Hash] the Crew record as the ledger holds it, each value object as its value
  def up(hecks, run, tapes, checkout: CHECKOUT)
    Hecks::Runtime::Caller.as(role: "Maintainer") do
      hecks.dispatch_flat("Hecks::Crew.Up", run: { value: run }, checkout: { value: checkout }, tapes: { value: tapes },
                                            turns: { value: 1 })
    end
    record(hecks, run)
  end

  def record(hecks, run)
    registry = hecks.registry
    found = registry.repository("Hecks", registry.bluebook("Hecks").aggregate("Crew")).find(run)
    Hecks::Runtime::Value.materialize(found.state).transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
  end
end
