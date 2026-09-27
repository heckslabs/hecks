require "spec_helper"
require "hecks/forms/port_argument"

# bin/present's `-p`/`--port` reader. Pins the `--port=8080` form being honored
# and a non-numeric `-p abc` not becoming port 0 (an ephemeral bind).
RSpec.describe Hecks::Forms::PortArgument do
  def parse(argv) = described_class.parse(argv)

  it "falls back to the default when neither spelling appears" do
    expect(parse([])).to eq([4567, nil])
  end

  it "reads the equals form" do
    expect(parse(["--port=8080"])).to eq([8080, nil])
  end

  it "reads -p and --port as separate argv entries" do
    expect(parse(["-p", "9000"])).to eq([9000, nil])
    expect(parse(["--port", "9001"])).to eq([9001, nil])
  end

  it "refuses a non-numeric value instead of silently becoming an ephemeral port" do
    port, error = parse(["-p", "abc"])
    expect(port).to be_nil
    expect(error).to include("whole number")
  end

  it "refuses an empty equals value" do
    port, error = parse(["--port="])
    expect(port).to be_nil
    expect(error).to include("requires a value")
  end

  it "refuses a port outside 1..65535" do
    port, error = parse(["-p", "0"])
    expect(port).to be_nil
    expect(error).to include("between 1 and 65535")

    port, error = parse(["-p", "70000"])
    expect(port).to be_nil
    expect(error).to include("between 1 and 65535")
  end

  it "refuses -p with no following value" do
    port, error = parse(["-p"])
    expect(port).to be_nil
    expect(error).to include("requires a value")
  end
end
