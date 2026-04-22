# spec/hecksagon/structure/shell_adapter_spec.rb
#
# Value-object contract for Hecksagon::Structure::ShellAdapter.
#
require_relative "../spec_helper"

RSpec.describe Hecksagon::Structure::ShellAdapter do
  let(:valid_attrs) do
    {
      name: :git_log,
      command: "git",
      args: ["log", "--format=%H", "{{range}}"],
      output_format: :lines,
      timeout: 10,
      working_dir: "/tmp",
      env: { "GIT_PAGER" => "" }
    }
  end

  describe "#initialize" do
    it "accepts a fully-specified adapter" do
      adapter = described_class.new(**valid_attrs)
      expect(adapter.name).to eq(:git_log)
      expect(adapter.command).to eq("git")
      expect(adapter.args).to eq(["log", "--format=%H", "{{range}}"])
      expect(adapter.output_format).to eq(:lines)
      expect(adapter.timeout).to eq(10)
      expect(adapter.working_dir).to eq("/tmp")
      expect(adapter.env).to eq("GIT_PAGER" => "")
    end

    it "defaults args to [], output_format to :text, env to {}" do
      adapter = described_class.new(name: :run, command: "echo")
      expect(adapter.args).to eq([])
      expect(adapter.output_format).to eq(:text)
      expect(adapter.env).to eq({})
      expect(adapter.timeout).to be_nil
      expect(adapter.working_dir).to be_nil
    end

    it "rejects a nil name" do
      expect { described_class.new(name: nil, command: "echo") }
        .to raise_error(ArgumentError, /name/)
    end

    it "rejects a nil or empty command" do
      expect { described_class.new(name: :x, command: nil) }
        .to raise_error(ArgumentError, /command/)
      expect { described_class.new(name: :x, command: "") }
        .to raise_error(ArgumentError, /command/)
    end

    it "rejects a command that contains placeholders" do
      expect { described_class.new(name: :x, command: "{{bin}}") }
        .to raise_error(ArgumentError, /\{\{/)
    end

    it "rejects args that are not Array<String>" do
      expect { described_class.new(name: :x, command: "echo", args: "hi") }
        .to raise_error(ArgumentError, /Array of Strings/)
      expect { described_class.new(name: :x, command: "echo", args: [1, 2]) }
        .to raise_error(ArgumentError, /Array of Strings/)
    end

    it "rejects unknown output_format values" do
      expect { described_class.new(name: :x, command: "echo", output_format: :xml) }
        .to raise_error(ArgumentError, /output_format/)
    end

    it "freezes args and env to prevent mutation" do
      adapter = described_class.new(**valid_attrs)
      expect(adapter.args).to be_frozen
      expect(adapter.env).to be_frozen
    end

    it "rejects a relative working_dir at build time" do
      # Security: `Dir.pwd` is a cwd-dependent implicit default. Forcing
      # absolute paths at IR-build time kills the class of bugs where a
      # dispatcher ran in the wrong directory because cwd had drifted.
      expect { described_class.new(name: :x, command: "echo", working_dir: ".") }
        .to raise_error(ArgumentError, /working_dir must be an absolute path/)
      expect { described_class.new(name: :x, command: "echo", working_dir: "relative/sub") }
        .to raise_error(ArgumentError, /working_dir must be an absolute path/)
    end

    it "accepts an absolute working_dir" do
      adapter = described_class.new(name: :x, command: "echo", working_dir: "/tmp")
      expect(adapter.working_dir).to eq("/tmp")
    end

    it "still accepts nil working_dir (dispatcher falls back to Dir.pwd)" do
      adapter = described_class.new(name: :x, command: "echo")
      expect(adapter.working_dir).to be_nil
    end
  end

  describe "#placeholders" do
    it "extracts {{token}} names from args" do
      adapter = described_class.new(
        name: :git_show,
        command: "git",
        args: ["show", "{{sha}}", "--format=", "{{sha}}", "--dir={{dir}}"]
      )
      expect(adapter.placeholders).to eq([:sha, :dir])
    end

    it "returns [] when no placeholders are present" do
      adapter = described_class.new(name: :ls, command: "ls", args: ["-la"])
      expect(adapter.placeholders).to eq([])
    end
  end

  describe "#to_h" do
    it "returns the full value-object shape" do
      adapter = described_class.new(**valid_attrs)
      expect(adapter.to_h).to eq(
        name: :git_log,
        command: "git",
        args: ["log", "--format=%H", "{{range}}"],
        output_format: :lines,
        timeout: 10,
        working_dir: "/tmp",
        env: { "GIT_PAGER" => "" }
      )
    end
  end
end
