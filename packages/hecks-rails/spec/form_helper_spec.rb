require "spec_helper"

RSpec.describe Hecks::Rails::FormHelper do
  let(:view) { ActionView::Base.empty }

  def form_for_open
    view.bluebook_form_for(Account, :open_account, url: "/accounts/open_account")
  end

  it "posts to the url given" do
    expect(form_for_open).to include('action="/accounts/open_account"', 'method="post"')
  end

  it "names each field by the dotted path the params reader expects", :aggregate_failures do
    expect(form_for_open).to include('name="number.value"', 'name="owner.name"', 'name="balance.cents"')
  end
end
