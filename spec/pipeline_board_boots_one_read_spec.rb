require "spec_helper"

# The Boot hours reading over a large day: the usage record is read once for the whole reading,
# never once for each signal, so the snapshot answers in seconds however many launcher runs a
# day holds.
RSpec.describe "the Boot hours reading over a large day" do
  let(:now) { Time.utc(2026, 11, 22, 12, 0, 0) }
  let(:reads) { [] }
  let(:rows) { Array.new(2_000) { |i| { "boot_ms" => 900, "caller" => "c#{i % 7}", "at" => (now - i).iso8601 } } }
  let(:reader) do
    source = lambda do |since|
      reads << since
      rows
    end
    Hecks::Adapters::PipelineBoots.new(settings: { entries: source, now: -> { now }, load: -> { 3.0 } })
  end

  it "reads the usage record once for the hours, the share and the storms" do
    reader.today

    expect(reads.size).to eq(1)
  end

  it "takes the boot share from that same read" do
    expect(reader.today[:share]).to be_positive
  end

  it "still prices every run of the day", :aggregate_failures do
    today = reader.today

    expect(today[:boots]).to eq(2_000)
    expect(today[:hours]).to eq(0.5)
  end
end
