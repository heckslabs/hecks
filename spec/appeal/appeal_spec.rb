# spec/appeal/appeal_spec.rb
#
# Integration tests for the Appeal IDE domain.
# Verifies the domain boots, commands dispatch, events fire,
# and the actor system wires up correctly.
#
require_relative "spec_helper"

RSpec.describe "Appeal IDE Domain" do
  let(:domain) { Hecks::Chapters::Appeal.definition }
  let(:runtime) do
    Hecks.load_bluebook(domain, skip_validation: true)
    Hecks::Runtime.new(domain)
  end

  describe "boot" do
    it "loads the Appeal definition" do
      expect(domain).not_to be_nil
      expect(domain.name).to eq("HecksAppeal")
    end

    it "has more than 30 aggregates" do
      expect(domain.aggregates.size).to be > 30
    end

    it "includes expected aggregate names" do
      names = domain.aggregates.map(&:name)
      %w[Layout Session Menu Feature Diagram Server].each do |name|
        expect(names).to include(name)
      end
    end
  end

  describe "runtime" do
    it "creates a runtime successfully" do
      expect(runtime).to be_a(Hecks::Runtime)
    end

    it "exposes the domain" do
      expect(runtime.domain.name).to eq("HecksAppeal")
    end

    it "has an event bus" do
      expect(runtime.event_bus).not_to be_nil
    end

    it "has a command bus" do
      expect(runtime.command_bus).not_to be_nil
    end
  end

  describe "Layout commands" do
    it "dispatches SelectTab" do
      events = []
      runtime.on("TabSelected") { |e| events << e }
      runtime.run("SelectTab", tab_name: "editor")
      expect(events.size).to eq(1)
    end

    it "dispatches ToggleSidebar" do
      events = []
      runtime.on("SidebarToggled") { |e| events << e }
      runtime.run("ToggleSidebar")
      expect(events.size).to eq(1)
    end

    it "dispatches ToggleEventsPanel" do
      events = []
      runtime.on("EventsPanelToggled") { |e| events << e }
      runtime.run("ToggleEventsPanel")
      expect(events.size).to eq(1)
    end
  end

  describe "Session commands" do
    it "dispatches EnterSketch" do
      events = []
      runtime.on("SketchEntered") { |e| events << e }
      runtime.run("EnterSketch")
      expect(events.size).to eq(1)
    end

    it "dispatches EnterPlay" do
      events = []
      runtime.on("PlayEntered") { |e| events << e }
      runtime.run("EnterPlay")
      expect(events.size).to eq(1)
    end
  end

  describe "Menu commands" do
    it "dispatches OpenMenu" do
      events = []
      runtime.on("MenuOpened") { |e| events << e }
      runtime.run("OpenMenu", menu_name: "File")
      expect(events.size).to eq(1)
    end

    it "dispatches CloseMenu" do
      events = []
      runtime.on("MenuClosed") { |e| events << e }
      runtime.run("CloseMenu")
      expect(events.size).to eq(1)
    end
  end

  describe "Feature commands" do
    it "dispatches CreateFeature and persists" do
      events = []
      runtime.on("FeatureCreated") { |e| events << e }
      runtime.run("CreateFeature", title: "Login", description: "User login flow")
      expect(events.size).to eq(1)
      expect(runtime["Feature"].all).not_to be_empty
    end
  end

  describe "event bus" do
    it "records events for dispatched commands" do
      runtime.run("SelectTab", tab_name: "console")
      runtime.run("EnterSketch")
      runtime.run("OpenMenu", menu_name: "View")
      expect(runtime.events.size).to be >= 3
    end
  end

  describe "actor system" do
    it "exists on the runtime" do
      expect(runtime.actor_system).not_to be_nil
    end

    it "has actors for each aggregate" do
      agg_names = domain.aggregates.map(&:name)
      agg_names.each do |name|
        expect(runtime.actor_system[name]).not_to be_nil
      end
    end
  end

  describe "bounded contexts" do
    it "has 6 .bluebook files in chapters/appeal/hecks/" do
      bluebook_dir = File.expand_path(
        "../../lib/hecks/chapters/appeal/hecks", __dir__
      )
      bluebooks = Dir[File.join(bluebook_dir, "*.bluebook")]
      expect(bluebooks.size).to eq(6)
    end
  end

  describe "projection auto-creation" do
    it "creates a projection for Layout" do
      expect(runtime.projection("Layout")).not_to be_nil
    end
  end
end
