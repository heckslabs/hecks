# frozen_string_literal: true

require "spec_helper"
require "hecks/rust_build"
require "hecks/rust_build/project_rust"

# The flags a corpus run hands `hecks project_rust` to name its declared domains.
RSpec.describe Hecks::RustBuild::ProjectRust::Declared do
  describe ".split" do
    it "reads nothing from a command line without the flags, leaving it whole", :aggregate_failures do
      declared, rest = described_class.split(["examples/pizzas"])

      expect(declared).to be_nil
      expect(rest).to eq(["examples/pizzas"])
    end

    it "takes the flags out and keeps the arguments left", :aggregate_failures do
      declared, rest = described_class.split(["--declared=banking,pizzas", "examples/pizzas", "--default=pizzas"])

      expect(declared.domains).to eq(%w[banking pizzas])
      expect(declared.default).to eq("pizzas")
      expect(rest).to eq(["examples/pizzas"])
    end

    it "refuses the domains without a default" do
      expect { described_class.split(["examples/pizzas", "--declared=banking,pizzas"]) }
        .to raise_error(Hecks::RustBuild::Failure, /go together/)
    end

    it "refuses a default that is not a declared domain" do
      expect { described_class.split(["examples/pizzas", "--declared=banking", "--default=pizzas"]) }
        .to raise_error(Hecks::RustBuild::Failure, /go together/)
    end
  end

  it "writes the flags it reads", :aggregate_failures do
    declared = described_class.new(%w[banking pizzas], "pizzas")

    expect(declared.flags).to eq(["--declared=banking,pizzas", "--default=pizzas"])
    expect(described_class.split(["examples/pizzas", *declared.flags]).first.domains).to eq(declared.domains)
  end

  it "is a whole run unless it says it is partial", :aggregate_failures do
    expect(described_class.new(%w[banking pizzas], "pizzas")).not_to be_partial
    expect(described_class.split(["examples/pizzas", "--declared=pizzas", "--default=pizzas"]).first).not_to be_partial
  end

  it "reads and writes the partial flag", :aggregate_failures do
    declared = described_class.new(%w[banking pizzas], "pizzas", partial: true)
    read, rest = described_class.split(["examples/pizzas", *declared.flags])

    expect(declared.flags).to eq(["--declared=banking,pizzas", "--default=pizzas", "--partial"])
    expect(read).to be_partial
    expect(rest).to eq(["examples/pizzas"])
  end
end
