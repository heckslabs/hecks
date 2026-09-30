RSpec.describe "the deprecated Facade constants" do
  it "resolves Hecks::Facade to Hecks::Doors and warns" do
    expect { expect(Hecks::Facade).to equal(Hecks::Doors) }
      .to output(/Hecks::Facade is deprecated and is removed in #{Hecks::Doors::REMOVAL}/).to_stderr
  end

  it "resolves a nested name through the alias" do
    expect { expect(Hecks::Facade::CliRunner).to equal(Hecks::Doors::CliRunner) }.to output(/deprecated/).to_stderr
  end

  it "resolves Doors::Surface to Doors::RubyDoor and warns" do
    expect { expect(Hecks::Doors::Surface).to equal(Hecks::Doors::RubyDoor) }
      .to output(/Hecks::Doors::Surface is deprecated.*use Hecks::Doors::RubyDoor/).to_stderr
  end

  it "still raises NameError for an unrelated missing constant" do
    expect { Hecks::NotAThing }.to raise_error(NameError, /NotAThing/)
  end

  it "does not warn for the new names" do
    expect { Hecks::Doors::RubyDoor }.not_to output.to_stderr
  end
end
