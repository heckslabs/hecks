require "spec_helper"

RSpec.describe Hecks::Rails::Actor do
  User = Struct.new(:id)
  Employee = Struct.new(:id, :actor_id)

  def controller_for(user) = Struct.new(:current_user).new(user)

  after { Hecks::Rails.actor_from { nil } && Hecks::Rails.instance_variable_set(:@actor_from, nil) }

  it "acts as the signed-in user's id" do
    expect(Hecks::Rails.actor_for(controller_for(User.new(7)))).to eq(actor_id: "7")
  end

  it "prefers an actor_id the user defines" do
    expect(Hecks::Rails.actor_for(controller_for(Employee.new(7, "emp-7")))).to eq(actor_id: "emp-7")
  end

  it "is anonymous when nobody is signed in" do
    expect(Hecks::Rails.actor_for(controller_for(nil))).to be_nil
  end

  it "takes a lookup declared once" do
    Hecks::Rails.actor_from { |controller| controller.current_user&.id&.then { |id| "u-#{id}" } }

    expect(Hecks::Rails.actor_for(controller_for(User.new(7)))).to eq(actor_id: "u-7")
  end
end
