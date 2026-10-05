require "spec_helper"

RSpec.describe "the spellings removed in 3.4.0" do
  it "no longer defines Hecks::Facade or Hecks::Doors::Surface" do
    expect(Hecks.const_defined?(:Facade, false)).to be false
    expect(Hecks::Doors.const_defined?(:Surface, false)).to be false
  end

  it "refuses the install_facade: keyword on every boot entry point" do
    expect { Hecks.boot("nowhere", install_facade: false) }.to raise_error(ArgumentError, /install_facade/)
    expect { Hecks.boot_files([], install_facade: false) }.to raise_error(ArgumentError, /install_facade/)
    expect { Hecks.boot_described(nil, install_facade: false) }.to raise_error(ArgumentError, /install_facade/)
  end
end
