# spec/tools/nursery_parity_sweep_spec.rb
#
# Smoke test for bin/nursery-parity-sweep. Runs the tool against a fabricated
# nursery fixture and confirms the four documented transformations fire
# correctly, idempotently, and do not corrupt unrelated lines.
#
# Fixtures live alongside this spec under spec/tools/fixtures/sweep/.

require "fileutils"
require "tmpdir"

RSpec.describe "bin/nursery-parity-sweep" do
  let(:bin)           { File.expand_path("../../bin/nursery-parity-sweep", __dir__) }
  let(:fixtures_dir)  { File.expand_path("fixtures/sweep", __dir__) }
  let(:input_path)    { File.join(fixtures_dir, "input.bluebook") }
  let(:expected_path) { File.join(fixtures_dir, "expected.bluebook") }

  def run_sweep(target, *flags)
    stdout = `#{bin} #{flags.join(' ')} #{target} 2>&1`
    [stdout, $?.exitstatus]
  end

  it "rewrites the fixture to match the expected output" do
    Dir.mktmpdir do |tmp|
      copy = File.join(tmp, "input.bluebook")
      FileUtils.cp(input_path, copy)

      stdout, status = run_sweep(copy)

      expect(status).to eq(0), "tool exited non-zero:\n#{stdout}"
      expect(File.read(copy)).to eq(File.read(expected_path)),
        "sweep output did not match expected fixture"
      expect(stdout).to include("files changed: 1")
      expect(stdout).to match(/1 +list_of\(X\) :f/)            # gate_a_swap
      expect(stdout).to match(/2 +reference_to "X"/)           # reference_to_string (2 sites)
      expect(stdout).to match(/1 +list_of "X"  +→/)            # list_of_string (one-line)
      expect(stdout).to match(/1 +list_of "X" do/)             # list_of_block_extract
    end
  end

  it "is idempotent — second run makes no changes" do
    Dir.mktmpdir do |tmp|
      copy = File.join(tmp, "input.bluebook")
      FileUtils.cp(input_path, copy)

      run_sweep(copy)                          # first pass
      first_pass = File.read(copy)
      stdout, status = run_sweep(copy)         # second pass
      second_pass = File.read(copy)

      expect(status).to eq(0)
      expect(second_pass).to eq(first_pass)
      expect(stdout).to include("files changed: 0")
    end
  end

  it "does not modify files in --dry-run mode" do
    Dir.mktmpdir do |tmp|
      copy = File.join(tmp, "input.bluebook")
      FileUtils.cp(input_path, copy)
      pre = File.read(copy)

      stdout, status = run_sweep(copy, "--dry-run")

      expect(status).to eq(0)
      expect(File.read(copy)).to eq(pre), "dry-run must not mutate the file"
      expect(stdout).to include("[DRY RUN]")
      expect(stdout).to include("files would change: 1")
    end
  end

  it "skips bluebook files that have no matching patterns" do
    Dir.mktmpdir do |tmp|
      clean = File.join(tmp, "clean.bluebook")
      File.write(clean, <<~BLUEBOOK)
        Hecks.bluebook "Clean" do
          aggregate "Widget" do
            attribute :name, String
            attribute :parts, list_of(Part)
            reference_to(Gadget)
          end
        end
      BLUEBOOK

      before = File.read(clean)
      stdout, status = run_sweep(clean)

      expect(status).to eq(0)
      expect(File.read(clean)).to eq(before)
      expect(stdout).to include("files changed: 0")
    end
  end
end
