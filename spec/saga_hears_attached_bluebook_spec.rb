require "spec_helper"
require "tmpdir"
require "fileutils"

# A domain's saga that starts on an event of a bluebook the domain attaches: a project `Shop`
# vendors `Widgets` and declares a process manager that starts when a widget is requested.
module AttachedSagaProject
  PACKAGE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Widgets" do
      vision "Ask for a widget."

      aggregate "Widget" do
        description "One widget asked for."
        attribute :run, RunKey
        identified_by :run

        value_object "RunKey" do
          attribute :value, String, matches: :present
        end

        command "Make" do
          goal "Ask for a widget to be made"
          attribute :run, RunKey, sets: true
          emits WidgetRequested
        end
      end
    end
  BLUEBOOK

  PROJECT = <<~BLUEBOOK.freeze
    Hecks.bluebook "Shop" do
      vision "A project whose saga follows a vendored widget."

      aggregate "Order" do
        description "The shop's note that a widget was packed."
        attribute :run, RunKey
        identified_by :run

        value_object "RunKey" do
          attribute :value, String, matches: :present
        end

        command "Pack" do
          goal "Note that the widget of a run was packed"
          attribute :run, RunKey, sets: true
          emits OrderPacked
        end
      end

      process_manager "Fulfilment" do
        correlates_by :"run.value"
        starts_on Widget::WidgetRequested

        transition Order::OrderPacked => "packed", from: "asked"
      end
    end
  BLUEBOOK

  HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Shop" do
      attaches "widgets", from: :vendor
    end

    Hecks.hecksagon "Widgets" do
    end
  HECKSAGON

  FILES = { "bluebook/shop.bluebook" => PROJECT, "bluebook/shop.hecksagon" => HECKSAGON,
            "vendor/embryonaut_bluebooks/widgets/bluebook/widgets.bluebook" => PACKAGE }.freeze

  # Boots the project in a temporary root.
  def booted
    Dir.mktmpdir("hecks-attached-saga") do |root|
      FILES.each { |path, text| write(File.join(root, path), text) }
      yield Hecks.boot(File.join(root, "bluebook"), install_driving: false, environment: HecksMemoryEnvironment::NAME)
    end
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def make(runtime, run) = runtime.dispatch("Widgets::Widget.Make", with: { run: { value: run } })

  def pack(runtime, run) = runtime.dispatch("Shop::Order.Pack", with: { run: { value: run } })

  def saga(runtime, run) = runtime.registry.saga_instances["Fulfilment"][run]
end

RSpec.describe "a saga that hears a bluebook its domain attaches" do
  include AttachedSagaProject

  it "starts on the attached bluebook's event" do
    booted do |runtime|
      make(runtime, "w1")
      expect(saga(runtime, "w1")).to include(state: "asked")
    end
  end

  it "moves on its own bluebook's event once started" do
    booted do |runtime|
      make(runtime, "w1")
      pack(runtime, "w1")
      expect(saga(runtime, "w1")).to include(state: "packed")
    end
  end

  it "starts nothing for an event of its own that no attached event began" do
    booted do |runtime|
      pack(runtime, "w2")
      expect(saga(runtime, "w2")).to be_nil
    end
  end

  it "names the saga with its own bluebook in the outbox row of the attached event" do
    booted do |runtime|
      event = Hecks::Runtime::Event.new(name: "WidgetRequested", aggregate: "Widgets::Widget", id: "w1", payload: {})
      rows = Hecks::Runtime::Outbox::Fanout.sagas(runtime.registry, event, "Widgets", "uid")
      expect(rows.map(&:consumer)).to eq(["saga:Shop::Fulfilment"])
    end
  end
end
