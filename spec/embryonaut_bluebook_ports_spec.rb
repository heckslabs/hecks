require "spec_helper"
require "tmpdir"
require "fileutils"

# A vendored package that asks the outside: its bluebook, the ports file beside it and the adapter
# bound to the port, attached by a project that declares none of the three.
module VendoredPortsProject
  PACKAGE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Widgets" do
      vision "Make a widget by asking the outside."

      aggregate "Widget" do
        description "One widget, made or refused."
        attribute :run, RunKey
        attribute :report, Report, optional: true
        identified_by :run

        value_object "RunKey" do
          attribute :value, String, matches: :present
        end

        value_object "Report", String

        command "Make" do
          goal "Ask for a widget to be made"
          attribute :run, RunKey, sets: true
          emits WidgetRequested
        end

        command "Record" do
          goal "Record the widget the outside made"
          reference_to Widget
          attribute :report, Report, sets: true
          emits WidgetMade
        end
      end

      policy "BuildWhenRequested" do
        on  "Widget.WidgetRequested"
        ask :build, with: { run: :run }
      end

      policy "RecordTheBuild" do
        on      "Widget.BuildAnswered"
        trigger Widget::Record, with: { report: :report }
      end
    end
  BLUEBOOK

  PORTS = <<~HECKSAGON.freeze
    Hecks.hecksagon "Widgets" do
      Widgets::Widget.port "Building" do
        asks "Build", to: Widget do
          attribute :run, RunKey
          answers "BuildAnswered"
          refuses "BuildRefused"
        end
      end
    end
  HECKSAGON

  ADAPTER = <<~ADAPTER.freeze
    module Hecks
      module Adapters
        class VendoredWidgetBuilder
          def initialize(aggregate: nil); end

          def build(**) = { report: { value: "built by the package's own adapter" } }
        end
      end
    end

    Hecks.adapter "VendoredWidgetBuilder" do
      port "Building"
    end
  ADAPTER

  PROJECT = <<~BLUEBOOK.freeze
    Hecks.bluebook "Shop" do
      vision "A project that vendors widgets."

      aggregate "Counter" do
        description "The shop's own aggregate."
        attribute :name, Name
        identified_by :name

        value_object "Name" do
          attribute :value, String, matches: :present
        end
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

  # Writes the project and its vendored package under a root.
  def write_project(root, files)
    package = "vendor/embryonaut_bluebooks/widgets/bluebook"
    own = { "bluebook/shop.bluebook" => PROJECT, "bluebook/shop.hecksagon" => HECKSAGON }
    vendored = { "widgets.bluebook" => PACKAGE }.merge(files).transform_keys { |name| "#{package}/#{name}" }
    own.merge(vendored).each { |path, text| write(File.join(root, path), text) }
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # Boots the project in a temporary root holding the package's named files.
  def booted(files)
    Dir.mktmpdir("hecks-vendored-ports") do |root|
      write_project(root, files)
      yield Hecks.boot(File.join(root, "bluebook"), install_driving: false, environment: HecksMemoryEnvironment::NAME)
    end
  end
end

RSpec.describe "a vendored package that declares ports" do
  include VendoredPortsProject

  let(:whole) { { "widgets.ports.hecksagon" => VendoredPortsProject::PORTS, "widgets.adapter" => VendoredPortsProject::ADAPTER } }

  it "brings its port to the project that attaches it" do
    booted(whole) do |runtime|
      widget = runtime.registry.bluebook("Widgets").aggregates.find { |aggregate| aggregate.hecks_name == "Widget" }
      expect(widget.ports.map(&:name)).to include("Building")
    end
  end

  it "answers its ask with the adapter it carries" do
    booted(whole) do |runtime|
      runtime.dispatch("Widgets::Widget.Make", with: { run: { value: "w1" } })
      expect(runtime.events.map(&:name)).to include("BuildAnswered", "WidgetMade")
    end
  end

  it "refuses to boot when the package's ports file is left out, naming the ask" do
    expect { booted("widgets.adapter" => VendoredPortsProject::ADAPTER) { |runtime| runtime } }
      .to raise_error(Hecks::Runtime::WiringError, /ask :build matches no `asks` declared on Widget/)
  end

  # The digest of a package directory holding the named files.
  def digest_with(dir, files)
    files.each { |name, text| File.write(File.join(dir, name), text) }
    Hecks::EmbryonautBluebook::Lock.digest_of(dir)
  end

  it "counts the ports file in the package's digest" do
    Dir.mktmpdir("hecks-vendored-digest") do |dir|
      before = digest_with(dir, "widgets.bluebook" => VendoredPortsProject::PACKAGE)
      expect(digest_with(dir, "widgets.ports.hecksagon" => VendoredPortsProject::PORTS)).not_to eq(before)
    end
  end
end
