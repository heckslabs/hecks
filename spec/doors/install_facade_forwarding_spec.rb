RSpec.describe "the deprecated install_facade: keyword" do
  let(:root) { File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook") }
  let(:files) { [File.join(root, "pizzas.bluebook"), File.join(InMemoryDomain::ROOT, "examples/pizzas/pizzas_behaviors.hecksagon")] }

  it "warns and forwards false, so no door constants are installed" do
    installed = nil
    allow(Hecks::Doors::RubyDoor).to receive(:install) do |dispatcher|
      installed = true
      dispatcher
    end

    expect { Hecks.boot_files(files, install_facade: false) }
      .to output(/`install_facade:` is deprecated and is removed in #{Hecks::Doors::REMOVAL}/).to_stderr
    expect(installed).to be_nil
  end

  it "warns and forwards true to the door install" do
    installed = nil
    allow(Hecks::Doors::RubyDoor).to receive(:install) do |dispatcher|
      installed = true
      dispatcher
    end

    expect { Hecks.boot_files(files, install_facade: true) }.to output(/deprecated/).to_stderr
    expect(installed).to be(true)
  end

  it "does not warn for install_doors:" do
    expect { Hecks.boot_files(files, install_doors: false) }.not_to output.to_stderr
  end

  it "resolves through Doors.install?" do
    expect { expect(Hecks::Doors.install?(true, false)).to be(false) }.to output(/deprecated/).to_stderr
    expect(Hecks::Doors.install?(true)).to be(true)
  end
end
