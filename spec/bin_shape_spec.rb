require "tmpdir"
require "open3"
require "json"
require "hecks/ports/persistence/plugins/era"

# bin/shape is a script, not a library, so this runs it as a real subprocess
# against real files — the same approach spec/bin_stores_spec.rb takes.
#
# Covers the two modes: one bluebook file prints the shape projection as JSON,
# a directory prints one "<Domain> <label>" line per domain declared by the
# `*.bluebook` files directly in it.
RSpec.describe "bin/shape" do
  BIN_SHAPE_SCRIPT = File.join(InMemoryDomain::ROOT, "bin/shape").freeze

  def bluebook_text(domain, aggregate)
    <<~BLUEBOOK
      Hecks.bluebook "#{domain}" do
        aggregate "#{aggregate}" do
          identified_by :name
          attribute :name, #{aggregate}Name
          value_object "#{aggregate}Name" do
            attribute :value, String
            invariant("named") { !value.to_s.empty? }
          end
          command "Create" do
            attribute :name, #{aggregate}Name
            sets :name
            emits "#{aggregate}Created"
          end
        end
      end
    BLUEBOOK
  end

  # The label the era plugin would mint for the file, computed in this
  # process from the same loading steps the script uses.
  def label_of(path)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(File.read(path), TOPLEVEL_BINDING, path, 1)
    end
    Hecks::Runtime::StorageShape.mint_label(registry.bluebooks.values.first)
  end

  def run_shape(*args)
    Open3.capture3(BIN_SHAPE_SCRIPT, *args)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  it "prints the shape projection of one bluebook file as JSON" do
    file = File.join(@dir, "zebras.bluebook")
    File.write(file, bluebook_text("Zebras", "Stripe"))

    stdout, _stderr, status = run_shape(file)

    expect(status).to be_success
    expect(JSON.parse(stdout)["name"]).to eq("Zebras")
  end

  it "prints one sorted '<Domain> <label>' line per domain in a directory" do
    zebras = File.join(@dir, "zebras.bluebook")
    apples = File.join(@dir, "apples.bluebook")
    File.write(zebras, bluebook_text("Zebras", "Stripe"))
    File.write(apples, bluebook_text("Apples", "Pip"))

    stdout, stderr, status = run_shape(@dir)

    expect(stderr).to eq("")
    expect(status).to be_success
    expect(stdout.lines.map(&:chomp)).to eq(["Apples #{label_of(apples)}", "Zebras #{label_of(zebras)}"])
  end

  it "answers a different label when a domain's storage shape changes" do
    File.write(File.join(@dir, "apples.bluebook"), bluebook_text("Apples", "Pip"))
    before, = run_shape(@dir)

    File.write(File.join(@dir, "apples.bluebook"), bluebook_text("Apples", "Core"))
    after, = run_shape(@dir)

    expect(before.split.first).to eq("Apples")
    expect(after.split.first).to eq("Apples")
    expect(after).not_to eq(before)
  end

  it "reads only the files directly in the directory, and only *.bluebook ones" do
    File.write(File.join(@dir, "apples.bluebook"), bluebook_text("Apples", "Pip"))
    File.write(File.join(@dir, "notes.txt"), "not a bluebook")
    FileUtils.mkdir_p(File.join(@dir, "nested"))
    File.write(File.join(@dir, "nested", "zebras.bluebook"), bluebook_text("Zebras", "Stripe"))

    stdout, _stderr, status = run_shape(@dir)

    expect(status).to be_success
    expect(stdout.lines.map { |line| line.split.first }).to eq(["Apples"])
  end

  it "refuses a directory with no *.bluebook files" do
    stdout, stderr, status = run_shape(@dir)

    expect(status).not_to be_success
    expect(stdout).to eq("")
    expect(stderr).to include("no *.bluebook files in #{@dir}")
  end

  it "refuses a path that does not exist" do
    missing = File.join(@dir, "nowhere")

    _stdout, stderr, status = run_shape(missing)

    expect(status).not_to be_success
    expect(stderr).to include("#{missing} does not exist")
  end

  it "requires a path at all" do
    _stdout, stderr, status = run_shape

    expect(status).not_to be_success
    expect(stderr).to include("usage: bin/shape")
  end
end
