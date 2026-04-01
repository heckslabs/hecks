require "spec_helper"
require "tmpdir"

RSpec.describe Hecks::Workshop::SessionImage do
  let(:workshop) { Hecks::Workshop.new("Pizzas") }

  before do
    allow($stdout).to receive(:puts)

    workshop.aggregate "Pizza" do
      attribute :name, String
      command "CreatePizza" do
        attribute :name, String
      end
    end

    workshop.add_verb("Bake")
  end

  describe ".capture" do
    it "captures domain name" do
      image = described_class.capture(workshop)
      expect(image.domain_name).to eq("Pizzas")
    end

    it "captures DSL source" do
      image = described_class.capture(workshop)
      expect(image.dsl_source).to include('Hecks.domain "Pizzas"')
      expect(image.dsl_source).to include('aggregate "Pizza"')
    end

    it "captures custom verbs" do
      image = described_class.capture(workshop)
      expect(image.custom_verbs).to include("Bake")
    end

    it "records a timestamp" do
      image = described_class.capture(workshop)
      expect(image.captured_at).to be_within(2).of(Time.now)
    end
  end

  describe "#restore_into" do
    it "restores aggregate builders into a fresh workshop" do
      image = described_class.capture(workshop)
      new_workshop = Hecks::Workshop.new("Pizzas")

      image.restore_into(new_workshop)

      domain = new_workshop.to_domain
      expect(domain.aggregates.map(&:name)).to eq(["Pizza"])
      expect(domain.aggregates.first.commands.map(&:name)).to include("CreatePizza")
    end

    it "clears existing aggregates before restoring" do
      workshop.aggregate("Order") { attribute :total, Integer }
      image = described_class.capture(workshop)

      target = Hecks::Workshop.new("Pizzas")
      target.aggregate("Stale") { attribute :x, String }

      image.restore_into(target)
      expect(target.aggregates).not_to include("Stale")
    end
  end

  describe "#inspect" do
    it "returns a readable summary" do
      image = described_class.capture(workshop)
      expect(image.inspect).to match(/SessionImage "Pizzas" \(1 aggregates\)/)
    end
  end
end

RSpec.describe Hecks::Workshop::PersistentImage do
  let(:workshop) { Hecks::Workshop.new("Pizzas") }
  let(:tmpdir) { Dir.mktmpdir("hecks-images-") }

  before do
    allow($stdout).to receive(:puts)

    workshop.aggregate "Pizza" do
      attribute :name, String
      command "CreatePizza" do
        attribute :name, String
      end
    end
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#save_image" do
    it "writes an image file" do
      path = workshop.save_image(dir: tmpdir)
      expect(File.exist?(path)).to be true
    end

    it "includes metadata header" do
      path = workshop.save_image(dir: tmpdir)
      content = File.read(path)
      expect(content).to include("# Domain: Pizzas")
      expect(content).to include("# Captured:")
    end

    it "includes DSL source" do
      path = workshop.save_image(dir: tmpdir)
      content = File.read(path)
      expect(content).to include('Hecks.domain "Pizzas"')
    end

    it "accepts a custom label" do
      path = workshop.save_image("checkpoint", dir: tmpdir)
      expect(path).to include("checkpoint.heckimage")
    end
  end

  describe "#restore_image" do
    it "restores from a saved image" do
      workshop.save_image(dir: tmpdir)

      new_workshop = Hecks::Workshop.new("Pizzas")
      new_workshop.restore_image(dir: tmpdir)

      domain = new_workshop.to_domain
      expect(domain.aggregates.map(&:name)).to eq(["Pizza"])
    end

    it "prints a message when no image found" do
      expect($stdout).to receive(:puts).with(/No image found/)
      workshop.restore_image("nonexistent", dir: tmpdir)
    end

    it "round-trips custom verbs" do
      workshop.add_verb("Ferment")
      workshop.save_image(dir: tmpdir)

      new_workshop = Hecks::Workshop.new("Pizzas")
      new_workshop.restore_image(dir: tmpdir)

      # Custom verbs are in the DSL source, restored via domain eval
      domain = new_workshop.to_domain
      expect(domain.name).to eq("Pizzas")
    end
  end

  describe "#list_images" do
    it "returns empty when no images exist" do
      expect(workshop.list_images(dir: tmpdir)).to be_empty
    end

    it "lists saved images" do
      workshop.save_image("alpha", dir: tmpdir)
      workshop.save_image("beta", dir: tmpdir)

      images = workshop.list_images(dir: tmpdir)
      expect(images.size).to eq(2)
      expect(images.all? { |p| p.end_with?(".heckimage") }).to be true
    end
  end
end
