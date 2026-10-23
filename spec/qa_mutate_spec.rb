require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/quality_control/cli/qa_mutate"

# `hecks quality_control target.mutate` against a stand-in `cargo` that writes cargo-mutants'
# outcome files, so the real minutes-long run is never paid here.
RSpec.describe Hecks::QualityControlCli::QaMutate do
  # Records its arguments, writes the outcome files `FAKE_MISSED` asks for, and exits with
  # cargo-mutants' own status for that outcome.
  FAKE_CARGO = <<~SH.freeze
    #!/bin/sh
    echo "$@" > "$FAKE_ARGS"
    while [ "$1" != "--output" ]; do shift; done
    out="$2/mutants.out"
    mkdir -p "$out"
    printf 'src/kernel/dispatch.rs:1:1: replace a with b in kept\\n' > "$out/caught.txt"
    if [ -n "$FAKE_MISSED" ]; then printf '%s\\n' "$FAKE_MISSED" > "$out/missed.txt"; exit 2; fi
    exit "${FAKE_EXIT:-0}"
  SH

  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, "rust"))
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin/cargo"), FAKE_CARGO)
      File.chmod(0o755, File.join(dir, "bin/cargo"))
      original_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{File.join(dir, "bin")}:#{original_path}"
      example.run
    ensure
      ENV["PATH"] = original_path
    end
  end

  # The stand-in reads its `FAKE_*` settings from the real environment, since it is a child process.
  def mutate(*argv, **env)
    env = { "FAKE_ARGS" => File.join(@root, "args") }.merge(env)
    with_env(env) do
      status = nil
      out = capture_stdout { status = described_class.call(argv, root: @root, env: ENV.to_h) }
      [out, status]
    end
  end

  def with_env(env)
    previous = env.to_h { |key, _| [key, ENV.fetch(key, nil)] }
    env.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def cargo_args = File.read(File.join(@root, "args"))

  it "is clean, with the kill rate, when every mutant is caught", :aggregate_failures do
    out, status = mutate("--file", "rust/src/kernel/dispatch.rs")

    expect(status).to eq(0)
    expect(out).to include("mutation: 1 caught, 0 missed, 0 timeout, 0 unviable; kill rate 100.0%")
    expect(cargo_args).to include("mutants --in-place --no-shuffle", "--file src/kernel/dispatch.rs")
  end

  it "reports each surviving mutant and exits 2", :aggregate_failures do
    out, status = mutate("--file", "rust/src/kernel/dispatch.rs",
                         "FAKE_MISSED" => "src/kernel/dispatch.rs:9:5: replace + with - in total")

    expect(status).to eq(2)
    expect(out).to include("kill rate 50.0%", "FOUND SOMETHING (1 mutant(s) no test caught):",
                           "  src/kernel/dispatch.rs:9:5: replace + with - in total")
  end

  it "takes the files from the dials, and never runs the equivalent mutants", :aggregate_failures do
    _, status = mutate("--from-dials")

    expect(status).to eq(0)
    expect(cargo_args).to include("--file src/kernel/dispatch.rs", "--file src/kernel/orchestrate.rs",
                                  "--exclude-re replace\\ <\\ with\\ <=\\ in\\ aggregate_position")
  end

  it "is off when QA_MUTATION_FILES names no file", :aggregate_failures do
    out, status = mutate("--from-dials", "QA_MUTATION_FILES" => "")

    expect(status).to eq(0)
    expect(out).to include("mutation: off (no mutation_files)")
    expect(File).not_to exist(File.join(@root, "args"))
  end

  it "is an operational error when cargo-mutants fails for any other reason" do
    expect { @status = mutate("--file", "rust/src/x.rs", "FAKE_EXIT" => "4").last }
      .to output(/cargo mutants ended with status 4/).to_stderr
      .and(change { @status }.to(1))
  end

  it "refuses an argument it does not take" do
    expect { @status = mutate("--bogus").last }
      .to output(/usage: hecks quality_control mutate/).to_stderr
      .and(change { @status }.to(1))
  end
end
