require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Deployment::Commands::DeployModel do
  describe "attributes" do
    subject(:command) { described_class.new(deployment_id: "example") }

    it "has deployment_id" do
      expect(command.deployment_id).to eq("example")
    end

  end

  describe "event" do
    it "emits DeployedModel" do
      expect(described_class.event_name).to eq("DeployedModel")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits DeployedModel" do
      agg = Deployment.plan(
          model_id: "example",
          environment: "example",
          endpoint: "example",
          purpose: "example",
          audience: "example"
        )
      Deployment.deploy_model(deployment_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("DeployedModel")
    end
  end
end
