require "tmpdir"
require "json"
require "hecks/ports/persistence/plugins/era"
require "hecks/hecks/adapters/in_process_boot"

# `hecks ask shape` (Introspection.Shape) against real files, through the adapter that answers
# it, covering both modes: a single bluebook file (JSON) and a directory (one line per domain).
RSpec.describe "hecks ask shape" do
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
  # process from the same loading steps the adapter uses.
  def label_of(path)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(File.read(path), TOPLEVEL_BINDING, path, 1)
    end
    Hecks::Runtime::StorageShape.mint_label(registry.bluebooks.values.first)
  end

  # Answers [stdout, error message]: the `Document` answer's text, or the refusal it raised.
  def run_shape(path)
    answer = Hecks::Adapters::InProcessBoot.new.shape(domain: path)
    [answer.is_a?(Hash) ? answer.fetch(:text) : answer, nil]
  rescue Hecks::Runtime::NotFound => e
    ["", e.message]
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  # Writes `name`.bluebook into the scratch directory; answers its path.
  def write_bluebook(name, domain, aggregate)
    File.join(@dir, "#{name}.bluebook").tap { |path| File.write(path, bluebook_text(domain, aggregate)) }
  end

  # What the directory's shape reads when apples.bluebook declares the given aggregate.
  def shape_with_apple(aggregate)
    write_bluebook("apples", "Apples", aggregate)
    run_shape(@dir).first
  end

  # A text file and a nested bluebook, neither of which is directly in the directory as a *.bluebook.
  def write_stray_files
    File.write(File.join(@dir, "notes.txt"), "not a bluebook")
    FileUtils.mkdir_p(File.join(@dir, "nested"))
    File.write(File.join(@dir, "nested", "zebras.bluebook"), bluebook_text("Zebras", "Stripe"))
  end

  it "prints the shape projection of one bluebook file as JSON", :aggregate_failures do
    file = write_bluebook("zebras", "Zebras", "Stripe")

    stdout, error = run_shape(file)

    expect(error).to be_nil
    expect(JSON.parse(stdout)["name"]).to eq("Zebras")
  end

  it "prints one sorted '<Domain> <label>' line per domain in a directory", :aggregate_failures do
    zebras = write_bluebook("zebras", "Zebras", "Stripe")
    apples = write_bluebook("apples", "Apples", "Pip")

    stdout, error = run_shape(@dir)

    expect(error).to be_nil
    expect(stdout.lines.map(&:chomp)).to eq(["Apples #{label_of(apples)}", "Zebras #{label_of(zebras)}"])
  end

  it "answers a different label when a domain's storage shape changes", :aggregate_failures do
    before = shape_with_apple("Pip")
    after = shape_with_apple("Core")

    expect([before, after].map { |text| text.split.first }).to eq(%w[Apples Apples])
    expect(after).not_to eq(before)
  end

  it "reads only the files directly in the directory, and only *.bluebook ones", :aggregate_failures do
    write_bluebook("apples", "Apples", "Pip")
    write_stray_files

    stdout, error = run_shape(@dir)

    expect(error).to be_nil
    expect(stdout.lines.map { |line| line.split.first }).to eq(["Apples"])
  end

  it "refuses a directory with no *.bluebook files", :aggregate_failures do
    stdout, error = run_shape(@dir)

    expect(stdout).to eq("")
    expect(error).to include("no *.bluebook files in #{@dir}")
  end

  it "refuses a path that does not exist" do
    missing = File.join(@dir, "nowhere")

    _stdout, error = run_shape(missing)

    expect(error).to include("#{missing} does not exist")
  end
end
