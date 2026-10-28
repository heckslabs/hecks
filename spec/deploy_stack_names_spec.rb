require "spec_helper"
require "hecks/adapters/driven/lambda"
require "hecks/projections/deploy/lambda/stack"
require "hecks/projections/deploy/fargate/stack"

# The `hecks-<domain, lowercased>` stack name is computed in four places that must agree: the
# Lambda client, the Lambda and Fargate stack generators' shared-owner lookup, and
# `function_name_for` in rust/host/core/src/lambda_client.rs.
# spec/fixtures/stack_name_vectors.json is the one table all of them assert; nothing is
# centralised, the copies are only pinned together.
RSpec.describe "the shared stack-name vectors" do
  STACK_NAME_VECTORS = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec", "fixtures", "stack_name_vectors.json")))

  # The generators read the owner off `deploy_settings`; this builds one without a world.
  def owner_stack_name(stack_class, owner_reader, owner)
    stack = stack_class.allocate
    stack.instance_variable_set(:@deploy_settings, { owner: owner })
    stack.instance_variable_set(:@shared, true)
    stack.instance_variable_set(:@infra_name, "x")
    stack.send(owner_reader)
    stack.owner_stack_name
  end

  before do
    require "aws-sdk-lambda"
    allow(Aws::Lambda::Client).to receive(:new).and_return(instance_double(Aws::Lambda::Client))
  end

  STACK_NAME_VECTORS.fetch("rows").each do |row|
    describe row["domain"].inspect do
      it "Lambda::Client names #{row["name"]}" do
        client = Hecks::Adapters::Lambda::Client.new(domain: row["domain"], region: "us-east-1")

        expect(client.function_name).to eq(row["name"])
      end

      it "the Lambda stack's shared owner is #{row["name"]}" do
        stack = Hecks::Projections::Deploy::Lambda::Stack
        expect(owner_stack_name(stack, :read_shared_owner, row["domain"])).to eq(row["name"])
      end

      it "the Fargate stack's shared owner is #{row["name"]}" do
        stack = Hecks::Projections::Deploy::Fargate::Stack
        expect(owner_stack_name(stack, :read_owner, row["domain"])).to eq(row["name"])
      end
    end
  end
end
