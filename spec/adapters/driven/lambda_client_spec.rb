require "hecks"
require "hecks/adapters/driven/lambda"

# THE NAME THE CLIENT ACTUALLY INVOKES — computed from the domain unless
# the deployment named it, in which case the name wins outright. Neither
# path touches AWS: `Aws::Lambda::Client.new` is stubbed, since what is
# under test is the string, not the transport.
RSpec.describe Hecks::Adapters::Lambda::Client do
  before do
    require "aws-sdk-lambda"
    allow(Aws::Lambda::Client).to receive(:new).and_return(instance_double(Aws::Lambda::Client))
  end

  it "computes `hecks-<domain>`, lowercased, when nothing names the function" do
    client = described_class.new(domain: "Pizzas", region: "us-east-1")

    expect(client.function_name).to eq("hecks-pizzas")
  end

  it "uses the named function verbatim — a real stack whose name that computation can never produce" do
    client = described_class.new(domain: "EmbryonautFoundersApp", region: "us-east-1",
                                 function: "hecksagain-embryonaut")

    expect(client.function_name).to eq("hecksagain-embryonaut")
  end

  it "treats an empty name as no name at all, rather than invoking an empty string" do
    client = described_class.new(domain: "Pizzas", region: "us-east-1", function: "")

    expect(client.function_name).to eq("hecks-pizzas")
  end
end
