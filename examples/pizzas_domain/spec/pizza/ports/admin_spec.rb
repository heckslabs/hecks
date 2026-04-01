require_relative "../../spec_helper"

RSpec.describe "Pizza :admin port" do
  before { @app = Hecks.load(domain, gate: :admin, force: true) }

  it "allows .find" do
    expect { Pizza.find("nonexistent") }.not_to raise_error
  end

  it "allows .all" do
    expect { Pizza.all }.not_to raise_error
  end

  it "denies .count" do
    expect { Pizza.count }.to raise_error(Hecks::GateAccessDenied)
  end

  it "denies .create" do
    expect { Pizza.create(name: "example", description: "example") }.to raise_error(Hecks::GateAccessDenied)
  end

end
