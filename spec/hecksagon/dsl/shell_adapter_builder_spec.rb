# spec/hecksagon/dsl/shell_adapter_builder_spec.rb
#
# Contract for Hecksagon::DSL::ShellAdapterBuilder.
#
require_relative "../spec_helper"

RSpec.describe Hecksagon::DSL::ShellAdapterBuilder do
  describe "#build" do
    it "builds a ShellAdapter from DSL block attrs" do
      builder = described_class.new(:git_log)
      builder.command "git"
      builder.args ["log", "--format=%H", "{{range}}"]
      builder.output_format :lines
      builder.timeout 10
      builder.working_dir "/tmp"
      builder.env "GIT_PAGER" => ""

      adapter = builder.build
      expect(adapter).to be_a(Hecksagon::Structure::ShellAdapter)
      expect(adapter.name).to eq(:git_log)
      expect(adapter.command).to eq("git")
      expect(adapter.args).to eq(["log", "--format=%H", "{{range}}"])
      expect(adapter.output_format).to eq(:lines)
      expect(adapter.timeout).to eq(10)
      expect(adapter.working_dir).to eq("/tmp")
      expect(adapter.env).to eq("GIT_PAGER" => "")
    end

    it "defaults args to [] and output_format to :text" do
      builder = described_class.new(:run)
      builder.command "echo"
      adapter = builder.build
      expect(adapter.args).to eq([])
      expect(adapter.output_format).to eq(:text)
      expect(adapter.env).to eq({})
    end

    it "merges multiple env calls" do
      builder = described_class.new(:x)
      builder.command "env"
      builder.env "A" => "1"
      builder.env "B" => "2"
      expect(builder.build.env).to eq("A" => "1", "B" => "2")
    end

    it "surfaces Structure validation errors at build time" do
      builder = described_class.new(:x)
      builder.command "{{bin}}"
      expect { builder.build }.to raise_error(ArgumentError, /\{\{/)
    end
  end

  describe "#apply_options" do
    it "applies keyword-argument shortcuts from the one-liner form" do
      builder = described_class.new(:git_show_files)
      builder.apply_options(
        command: "git",
        args: ["show", "--name-only", "{{sha}}"],
        output_format: :lines,
        timeout: 5
      )
      adapter = builder.build
      expect(adapter.command).to eq("git")
      expect(adapter.args).to eq(["show", "--name-only", "{{sha}}"])
      expect(adapter.output_format).to eq(:lines)
      expect(adapter.timeout).to eq(5)
    end

    it "lets block settings and apply_options coexist (block runs first in caller)" do
      builder = described_class.new(:mix)
      builder.command "seed_from_block"
      builder.apply_options(args: ["--kwarg"])
      adapter = builder.build
      expect(adapter.command).to eq("seed_from_block")
      expect(adapter.args).to eq(["--kwarg"])
    end
  end
end
