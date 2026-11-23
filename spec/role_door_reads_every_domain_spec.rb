require "spec_helper"
require_relative "support/role_door_checkout"
require "hecks/adapters/driving/mcp"

# A role's door reads every domain of its checkout and dispatches only the commands its routing
# rows name, and only in the Hecks domain.
RSpec.describe "a role's hecks door" do
  include RoleDoorCheckout

  before { open_checkout }

  after { close_checkout }

  it "answers a read in a domain other than the Hecks domain" do
    expect(answer("describe", { "domain" => "lib/hecks/tickets" })).not_to include("is refused")
  end

  it "answers a read that leaves out the domain, in the Hecks domain" do
    expect(answer("describe", {})).not_to include("is refused")
  end

  it "dispatches a command its routing names, in the Hecks domain" do
    text = answer("dispatch", { "domain" => "lib/hecks/hecks", "command" => "order.create_pizza", "dry_run" => true })
    expect(text).not_to include("is refused")
  end

  it "refuses a command outside its routing" do
    text = answer("dispatch", { "domain" => "lib/hecks/hecks", "command" => "order.purchase" })
    expect(text).to include("is refused")
  end

  it "refuses a command its routing names when it is dispatched in another domain" do
    text = answer("dispatch", { "domain" => "lib/hecks/tickets", "command" => "order.create_pizza" })
    expect(text).to include("is refused")
  end
end
