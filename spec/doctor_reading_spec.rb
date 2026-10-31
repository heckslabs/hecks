require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/doctor_reading"

RSpec.describe Hecks::Adapters::DoctorReading do
  subject(:doctor) { described_class.new }

  def checkout_with(overlay)
    dir = Dir.mktmpdir("doctor")
    File.write(File.join(dir, "rust-toolchain.toml"), %(channel = "1.98.0"\n))
    File.write(File.join(dir, "demo.local.world"), overlay) if overlay
    dir
  end

  it "reports a broken overlay as a failure with the file named" do
    text = doctor.doctor(domain: checkout_with("Hecks.world do\n"))[:text]
    expect(text).to include("FAIL  overlay files", "demo.local.world does not parse")
  end

  it "reports a clean overlay as ok" do
    text = doctor.doctor(domain: checkout_with(%(Hecks.world "X" do\nend\n)))[:text]
    expect(text).to include("OK    overlay files")
  end

  it "ends with the worst status of its checks" do
    text = doctor.doctor(domain: checkout_with("Hecks.world do\n"))[:text]
    expect(text.lines.last.strip).to eq("status: fail")
  end

  it "fails a file store whose directory is missing" do
    row = doctor.send(:file_store, "SqlitePersistence", "/no/such/dir/tickets.db")
    expect(row[1]).to eq(:fail)
  end
end
