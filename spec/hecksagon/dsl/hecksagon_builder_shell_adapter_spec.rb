# spec/hecksagon/dsl/hecksagon_builder_shell_adapter_spec.rb
#
# Contract for HecksagonBuilder#adapter dispatching on :shell vs. persistence.
# Also checks the deprecated #persistence alias still works.
#
require_relative "../spec_helper"

RSpec.describe Hecksagon::DSL::HecksagonBuilder do
  describe "#adapter :shell" do
    it "appends a shell adapter built from a block" do
      builder = described_class.new("App")
      builder.adapter :shell, name: :git_log do
        command "git"
        args ["log", "--format=%H", "{{range}}"]
        output_format :lines
        timeout 10
      end
      hecksagon = builder.build
      expect(hecksagon.shell_adapters.size).to eq(1)
      adapter = hecksagon.shell_adapter(:git_log)
      expect(adapter).to be_a(Hecksagon::Structure::ShellAdapter)
      expect(adapter.command).to eq("git")
      expect(adapter.args).to eq(["log", "--format=%H", "{{range}}"])
      expect(adapter.output_format).to eq(:lines)
      expect(adapter.timeout).to eq(10)
    end

    it "appends a shell adapter from the one-liner keyword form" do
      builder = described_class.new("App")
      builder.adapter :shell, name: :git_show_files,
                              command: "git",
                              args: ["show", "--name-only", "{{sha}}"],
                              output_format: :lines
      hecksagon = builder.build
      adapter = hecksagon.shell_adapter(:git_show_files)
      expect(adapter.command).to eq("git")
      expect(adapter.args).to eq(["show", "--name-only", "{{sha}}"])
      expect(adapter.output_format).to eq(:lines)
    end

    it "allows multiple distinct shell adapters" do
      builder = described_class.new("App")
      builder.adapter :shell, name: :a, command: "echo", args: ["a"]
      builder.adapter :shell, name: :b, command: "echo", args: ["b"]
      hecksagon = builder.build
      expect(hecksagon.shell_adapters.map(&:name)).to eq([:a, :b])
    end

    it "raises when name: is omitted" do
      builder = described_class.new("App")
      expect {
        builder.adapter :shell, command: "echo"
      }.to raise_error(ArgumentError, /name:/)
    end

    it "raises on duplicate adapter names within the same hecksagon" do
      builder = described_class.new("App")
      builder.adapter :shell, name: :dup, command: "echo"
      expect {
        builder.adapter :shell, name: :dup, command: "echo"
      }.to raise_error(ArgumentError, /already declared/)
    end
  end

  describe "#adapter (persistence kind)" do
    it "records persistence for non-shell kinds" do
      builder = described_class.new("App")
      builder.adapter :sqlite, database: "pizzas.db"
      hecksagon = builder.build
      expect(hecksagon.persistence).to eq(type: :sqlite, database: "pizzas.db")
      expect(hecksagon.shell_adapters).to be_empty
    end

    it "accepts :memory with no options" do
      builder = described_class.new("App")
      builder.adapter :memory
      hecksagon = builder.build
      expect(hecksagon.persistence).to eq(type: :memory)
    end
  end

  describe "#persistence (deprecated alias)" do
    it "still sets persistence and emits a deprecation warning on first call" do
      builder = described_class.new("App")
      expect {
        builder.persistence :sqlite, database: "x.db"
      }.to output(/deprecated/).to_stderr
      hecksagon = builder.build
      expect(hecksagon.persistence).to eq(type: :sqlite, database: "x.db")
    end

    it "warns only once per builder" do
      builder = described_class.new("App")
      builder.persistence :memory
      expect {
        builder.persistence :sqlite, database: "x.db"
      }.not_to output.to_stderr
    end
  end
end
