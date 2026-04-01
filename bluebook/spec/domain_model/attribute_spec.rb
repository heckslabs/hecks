require "spec_helper"

RSpec.describe Hecks::DomainModel::Structure::Attribute do
  describe "a simple attribute" do
    subject(:attr) { described_class.new(name: :name, type: String) }

    it "has a name" do
      expect(attr.name).to eq(:name)
    end

    it "has a type" do
      expect(attr.type).to eq(String)
    end

    it "is not a list" do
      expect(attr).not_to be_list
    end
  end

  describe "a list attribute" do
    subject(:attr) { described_class.new(name: :toppings, type: "Topping", list: true) }

    it "is a list" do
      expect(attr).to be_list
    end
  end

  describe "visibility" do
    it "is visible by default" do
      attr = described_class.new(name: :name, type: String)
      expect(attr.visible?).to be true
    end

    it "is hidden when visible: false" do
      attr = described_class.new(name: :password_digest, type: String, visible: false)
      expect(attr.visible?).to be false
    end
  end
end
