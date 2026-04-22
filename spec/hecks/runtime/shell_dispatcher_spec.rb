# spec/hecks/runtime/shell_dispatcher_spec.rb
#
# Contract for Hecks::Runtime::ShellDispatcher. Exercises placeholder
# substitution, every output_format branch, the security property
# (no shell expansion of placeholder payloads), timeout handling,
# and failure surface.
#
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "hecks"

RSpec.describe Hecks::Runtime::ShellDispatcher do
  def adapter(overrides = {})
    attrs = {
      name: :echo,
      command: "echo",
      args: ["{{msg}}"],
      output_format: :text
    }.merge(overrides)
    Hecksagon::Structure::ShellAdapter.new(**attrs)
  end

  describe ".substitute_placeholders" do
    it "substitutes {{name}} tokens per-element" do
      out = described_class.substitute_placeholders(
        ["git", "log", "{{range}}"],
        range: "HEAD~5..HEAD"
      )
      expect(out).to eq(["git", "log", "HEAD~5..HEAD"])
    end

    it "accepts string or symbol keys from attrs" do
      out = described_class.substitute_placeholders(
        ["{{a}}", "{{b}}"],
        "a" => "x", b: "y"
      )
      expect(out).to eq(["x", "y"])
    end

    it "leaves unknown placeholders untouched" do
      out = described_class.substitute_placeholders(
        ["--{{missing}}"],
        {}
      )
      expect(out).to eq(["--{{missing}}"])
    end

    it "stringifies non-string substitution values" do
      out = described_class.substitute_placeholders(["{{n}}"], n: 42)
      expect(out).to eq(["42"])
    end
  end

  describe ".call" do
    it "runs the command and returns :text output by default" do
      result = described_class.call(adapter, msg: "hello")
      expect(result.output).to eq("hello\n")
      expect(result.raw_stdout).to eq("hello\n")
      expect(result.exit_status).to eq(0)
    end

    it "parses :lines output format into an array of non-empty chomped lines" do
      adapter_lines = adapter(
        command: "printf",
        args: ["a\nb\n\nc\n"],
        output_format: :lines
      )
      result = described_class.call(adapter_lines)
      expect(result.output).to eq(%w[a b c])
    end

    it "parses :json output format" do
      adapter_json = adapter(
        command: "printf",
        args: ['{"a":1,"b":[2,3]}'],
        output_format: :json
      )
      result = described_class.call(adapter_json)
      expect(result.output).to eq("a" => 1, "b" => [2, 3])
    end

    it "parses :json_lines format (one JSON object per line)" do
      adapter_jl = adapter(
        command: "printf",
        args: ["{\"x\":1}\n{\"x\":2}\n"],
        output_format: :json_lines
      )
      result = described_class.call(adapter_jl)
      expect(result.output).to eq([{ "x" => 1 }, { "x" => 2 }])
    end

    it "returns exit_status as output for :exit_code format without raising" do
      adapter_ec = adapter(
        command: "sh",
        args: ["-c", "exit 3"],
        output_format: :exit_code
      )
      result = described_class.call(adapter_ec)
      expect(result.output).to eq(3)
      expect(result.exit_status).to eq(3)
    end

    it "raises ShellAdapterError on non-zero exit for non-:exit_code formats" do
      bad = adapter(
        command: "sh",
        args: ["-c", "echo boom >&2; exit 7"],
        output_format: :text
      )
      expect { described_class.call(bad) }.to raise_error(Hecks::ShellAdapterError) do |err|
        expect(err.adapter).to eq(:echo)
        expect(err.exit_status).to eq(7)
        expect(err.stderr).to include("boom")
      end
    end

    it "does NOT shell-expand placeholder payloads" do
      # Payload contains $(...) — a shell would try to execute date;
      # Open3.capture3 without a shell passes it as a literal argv element.
      payload = "$(date)"
      result = described_class.call(adapter, msg: payload)
      expect(result.raw_stdout.strip).to eq(payload)
    end

    it "raises ShellAdapterTimeoutError when timeout is exceeded" do
      # Timeout is a floating-point second. We use sleep 2 with timeout 0.2
      # to keep the test under the 1-second budget while proving the dispatcher
      # fires its timeout error before the child would have exited naturally.
      slow = Hecksagon::Structure::ShellAdapter.new(
        name: :slow, command: "sleep", args: ["2"],
        output_format: :exit_code, timeout: 0.2
      )
      expect { described_class.call(slow) }
        .to raise_error(Hecks::ShellAdapterTimeoutError) { |err| expect(err.adapter).to eq(:slow) }
    end

    it "only passes declared env; baseline is cleared" do
      env_adapter = adapter(
        command: "sh",
        args: ["-c", "echo pager=$GIT_PAGER home=$HOME"],
        env: { "GIT_PAGER" => "cat" }
      )
      result = described_class.call(env_adapter)
      # GIT_PAGER gets through because it's declared; HOME doesn't
      # because it wasn't declared.
      expect(result.raw_stdout).to match(/pager=cat/)
      expect(result.raw_stdout).to match(/home=\s*$/)
    end
  end
end
