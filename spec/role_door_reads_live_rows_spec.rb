require "spec_helper"
require_relative "support/role_door_kept_checkout"
require "hecks/adapters/driving/mcp"

# A role's door reads the kept rows of a bluebook the home domain attaches, as the launcher does,
# and still dispatches only the commands its routing names, in the Hecks domain.
RSpec.describe "a role's hecks door reading kept rows" do
  include RoleDoorKeptCheckout

  before { open_checkout }

  after { close_checkout }

  it "answers the kept Tenant row through state, read as the real door is started" do
    expect(door_answer("state", { "domain" => "lib/hecks/tenancy", "aggregate" => "Tenant", "summary" => "proof" }))
      .to include(RoleDoorKeptCheckout::SLUG)
  end

  it "answers the kept Tenant row through a declared query" do
    text = door_answer("query", { "domain" => "lib/hecks/tenancy", "question" => "tenant.active", "summary" => "proof" })
    expect(text).to include(RoleDoorKeptCheckout::SLUG)
  end

  it "answers the kept Tenant row through history" do
    expect(door_answer("history", { "domain" => "lib/hecks/tenancy" })).to include(RoleDoorKeptCheckout::SLUG)
  end

  it "refuses a dispatch naming the attached directory" do
    text = door_answer("dispatch", { "domain" => "lib/hecks/tenancy", "command" => "order.create_pizza" })
    expect(text).to include("is refused")
  end

  it "refuses a dispatch of an allowed command naming the attached directory" do
    text = door_answer("dispatch", { "domain" => "lib/hecks/tenancy", "command" => "order.create_pizza",
                                     "dry_run" => true })
    expect(text).to include("dispatches only in")
  end

  it "keeps a dispatch in the Hecks domain on the door's own boot" do
    text = door_answer("dispatch", { "domain" => "lib/hecks/hecks", "command" => "order.create_pizza",
                                     "dry_run" => true })
    expect(text).not_to include("is refused")
  end

  it "answers a read naming the Hecks domain from the door's own boot, with no kept tenant" do
    text = door_answer("describe", { "domain" => "lib/hecks/hecks" })
    expect(text).not_to include("is refused")
  end

  it "refuses a command outside its list in the Hecks domain" do
    text = door_answer("dispatch", { "domain" => "lib/hecks/hecks", "command" => "order.purchase" })
    expect(text).to include("is refused")
  end
end
