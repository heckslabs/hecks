# frozen_string_literal: true

require "spec_helper"
require "json"

# `policy_only` on a command and `acts_as` on a policy (ADR 0216): the bluebook words that say how
# a caller who states no role is treated. The Rust parser's reading of the same fixture is held to
# this IR byte for byte by spec/parser_parity_spec.rb, which compares every fixture bluebook.
RSpec.describe "policy_only and acts_as" do
  FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/role_unstated_caller.bluebook")

  # The fixture's IR as the exporter writes it, read back as JSON.
  def ruby_ir
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(FIXTURE)
    end
    JSON.parse(JSON.generate(Hecks::Projector::Exporter.call(registry).fetch("RoleUnstatedCaller")))
  end

  # One command of the fixture's IR, by name.
  def command_ir(name) = ruby_ir.fetch("aggregates").first.fetch("commands").find { |c| c["name"] == name }

  it "carries policy_only on the command that says it" do
    expect(command_ir("Water")).to include("policy_only" => true)
  end

  it "carries no policy_only key on a command that does not say it" do
    expect(command_ir("Wilt")).not_to have_key("policy_only")
  end

  it "carries the role a policy acts as" do
    expect(ruby_ir.fetch("policies").first).to include("acts_as" => "System")
  end

  it "refuses an acts_as that names no role" do
    build = -> { Hecks::Bluebook::DSL::PolicyBuilder.build("Blank") { acts_as "" } }
    expect(&build).to raise_error(Hecks::Bluebook::DSL::Malformed, /acts_as with no role/)
  end
end
