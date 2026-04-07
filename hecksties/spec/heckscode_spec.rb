# HecksCode Spec
#
# Verifies the HecksCode language specification module
# exposes syntax, compiler, runtime, type system, module
# system, and IO model as inspectable components.
#
require "spec_helper"
require "heckscode"

RSpec.describe HecksCode do
  it "exposes syntax keywords across multiple contexts" do
    syntax = described_class.syntax
    expect(syntax.keys).to include(:domain, :aggregate, :command)
    expect(syntax[:domain]).to include(:aggregate, :policy, :service)
    expect(syntax[:aggregate]).to include(:attribute, :command, :value_object)
  end

  it "describes the compiler pipeline" do
    compiler = described_class.compiler
    expect(compiler[:frontend]).to eq("Bluebook DSL")
    expect(compiler[:ir]).to eq("Hecks::DomainModel")
    expect(compiler[:backends]).to be_an(Array)
  end

  it "describes the runtime components" do
    runtime = described_class.runtime
    expect(runtime[:command_bus]).to include("CommandBus")
    expect(runtime[:event_bus]).to include("EventBus")
  end

  it "lists primitive types" do
    ts = described_class.type_system
    expect(ts[:primitives]).to include("String", "Integer", "Boolean")
  end

  it "describes the module system hierarchy" do
    ms = described_class.module_system
    expect(ms[:unit]).to include("Aggregate")
    expect(ms[:grouping]).to include("Chapter")
  end

  it "describes the IO model" do
    io = described_class.io_model
    expect(io[:ports]).to include("Commands")
    expect(io[:adapters]).to include("methods")
  end

  it "counts self-hosting chapters, aggregates, and commands" do
    sh = described_class.self_hosting
    expect(sh[:chapters]).to be >= 15
    expect(sh[:aggregates]).to be > 0
    expect(sh[:commands]).to be > 0
  end

  it "assembles a full spec hash" do
    spec = described_class.spec
    expect(spec.keys).to contain_exactly(
      :syntax, :compiler, :runtime, :type_system,
      :module_system, :io_model, :self_hosting
    )
  end
end
