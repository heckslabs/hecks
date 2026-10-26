require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/settings_reading"

# `hecks config`: what a copy resolves for each setting and which source supplied it.
RSpec.describe Hecks::Adapters::SettingsReading do
  let(:reading) { described_class.new }
  let(:directory) { Dir.mktmpdir("settings-reading") }
  let(:database) { "postgres://hecks:secret@localhost/hecks" }
  let(:variables) do
    %w[HECKS_ENVIRONMENT HECKS_DATABASE HECKS_SCHEMA HECKS_PROJECT_ENVIRONMENT HECKS_CACHE_DIR
       HECKS_RUST_DIR EMBRYONAUT_BLUEBOOKS_SRC] + described_class::DEPRECATED
  end

  def line(text, name) = text.lines.map(&:chomp).find { |entry| entry.start_with?("#{name}: ") }

  def read(**held) = reading.settings(domain: { value: directory }, **held).fetch(:text)

  before do
    @saved = variables.to_h { |name| [name, ENV.fetch(name, nil)] }
    variables.each { |name| ENV.delete(name) }
    registry = instance_double(Hecks::Runtime::Registry, default_database_for: database, first_domain_name: "Shop")
    described = instance_double(Hecks::Runtime::Loader::Described, registry: registry)
    allow(Hecks).to receive(:describe).with(directory).and_return(described)
  end

  after do
    @saved.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    FileUtils.remove_entry(directory)
  end

  it "reports the world's database with its password hidden", :aggregate_failures do
    text = read

    expect(line(text, "database")).to eq("database: postgres://hecks:***@localhost/hecks (world)")
    expect(text).not_to include("secret")
  end

  it "says the copy's own environments/local.world supplied the database" do
    FileUtils.mkdir_p(File.join(directory, "environments"))
    File.write(File.join(directory, "environments", "local.world"), "")

    expect(line(read, "database")).to end_with("(environments/local.world)")
  end

  it "reports the variable as the source, and as deprecated, when it is set" do
    ENV["HECKS_DATABASE"] = database

    expect(line(read, "database")).to include("variable HECKS_DATABASE, deprecated")
  end

  it "reports the environment as a variable when set and as the default when not", :aggregate_failures do
    expect(line(read, "environment")).to eq("environment: none (default)")

    ENV["HECKS_ENVIRONMENT"] = "memory"
    expect(line(read, "environment")).to eq("environment: memory (variable HECKS_ENVIRONMENT)")
  end

  it "lists a deprecated variable that is set, and nothing when none is", :aggregate_failures do
    expect(read).not_to include("deprecated variables set")

    ENV["HECKS_PRE_PUSH_GATE"] = "1"
    expect(read).to include("deprecated variables set: HECKS_PRE_PUSH_GATE")
  end

  it "finds the registry checkout beside the project and says so", :aggregate_failures do
    beside = File.join(File.dirname(directory), "embryonaut_bluebooks")
    Dir.mkdir(beside)

    expect(line(read, "registry source")).to eq("registry source: #{beside} (beside the project)")
  ensure
    FileUtils.remove_entry(beside) if beside && File.directory?(beside)
  end

  it "refuses a directory that is not there" do
    expect { reading.settings(domain: { value: File.join(directory, "missing") }) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /is not a directory/)
  end

  it "shows a database it could not read, not a crash" do
    allow(Hecks).to receive(:describe).with(directory).and_raise(StandardError, "no such bluebook")

    expect(line(read, "database")).to eq("database: could not be read (no such bluebook)")
  end
end
