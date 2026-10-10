require "spec_helper"

# `boot_described` finishes a boot from declarations `describe` already loaded, so a launcher that
# answers usage first and then runs a verb reads the domain's files once.
RSpec.describe "Hecks.boot_described" do
  let(:domain) { File.expand_path("../../examples/banking", __dir__) }

  it "binds a dispatcher to the registry describe loaded" do
    described = Hecks.describe(domain)

    dispatcher = Hecks.boot_described(described, install_driving: false)

    expect(dispatcher.registry).to be(described.registry)
  end

  it "does not read the domain again" do
    described = Hecks.describe(domain)
    allow(Hecks::Ports::Loading).to receive(:bootstrap)

    Hecks.boot_described(described, install_driving: false)

    expect(Hecks::Ports::Loading).not_to have_received(:bootstrap)
  end

  it "keeps the directory describe resolved, for the boot gates" do
    expect(Hecks.describe(domain).directory).to eq(Hecks::Ports::Loading.bootstrap.bluebook_directory(domain))
  end

  it "boots the same domain as Hecks.boot" do
    booted = Hecks.boot(domain, install_driving: false)
    finished = Hecks.boot_described(Hecks.describe(domain), install_driving: false)

    expect(finished.registry.bluebooks.keys).to eq(booted.registry.bluebooks.keys)
  end
end
