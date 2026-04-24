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

  describe "#adapter (persistence + io split — i67, 2026-04-24)" do
    # Mirrors Rust's hecksagon_parser absorb_adapter three-way dispatch :
    #   :shell              → shell_adapter
    #   :memory | :heki     → persistence
    #   anything else       → io_adapter
    # See docs/milestones/2026-04-24-direction-b-committed.md.

    it "records :memory as persistence (no options)" do
      builder = described_class.new("App")
      builder.adapter :memory
      hecksagon = builder.build
      expect(hecksagon.persistence).to eq(type: :memory)
      expect(hecksagon.io_adapters).to be_empty
    end

    it "records :heki as persistence" do
      builder = described_class.new("App")
      builder.adapter :heki, dir: "information"
      hecksagon = builder.build
      expect(hecksagon.persistence).to eq(type: :heki, dir: "information")
      expect(hecksagon.io_adapters).to be_empty
    end

    it "routes :sqlite to io_adapters, not persistence" do
      builder = described_class.new("App")
      builder.adapter :sqlite, database: "pizzas.db"
      hecksagon = builder.build
      expect(hecksagon.persistence).to be_nil
      expect(hecksagon.io_adapters.size).to eq(1)
      io = hecksagon.io_adapters.first
      expect(io.kind).to eq(:sqlite)
      expect(io.options).to eq(database: "pizzas.db")
    end

    it "routes :fs to io_adapters with options" do
      builder = described_class.new("App")
      builder.adapter :fs, root: "."
      hecksagon = builder.build
      expect(hecksagon.persistence).to be_nil
      expect(hecksagon.io_adapters.size).to eq(1)
      expect(hecksagon.io_adapters.first.kind).to eq(:fs)
      expect(hecksagon.io_adapters.first.options).to eq(root: ".")
    end

    it "routes :stdout / :stderr / :stdin to io_adapters with no options" do
      builder = described_class.new("App")
      builder.adapter :stdout
      builder.adapter :stderr
      hecksagon = builder.build
      expect(hecksagon.io_adapters.map(&:kind)).to eq([:stdout, :stderr])
    end

    it "collects on :Event declarations from block form" do
      builder = described_class.new("App")
      builder.adapter :fs, root: "." do
        on :Replicated
        on :Snapshotted
      end
      hecksagon = builder.build
      expect(hecksagon.io_adapters.first.on_events).to eq(%w[Replicated Snapshotted])
    end
  end

  describe "#persistence (deprecated alias — behaves like #adapter)" do
    it "emits a deprecation warning on first call" do
      builder = described_class.new("App")
      expect {
        builder.persistence :sqlite, database: "x.db"
      }.to output(/deprecated/).to_stderr
    end

    it "routes non-persistence kinds through to io_adapter (same as #adapter)" do
      # Post-i67 the deprecated alias still delegates to #adapter, which
      # now does the three-way split. :sqlite is an io kind, so it goes
      # to io_adapters rather than setting @persistence.
      builder = described_class.new("App")
      silence_stderr { builder.persistence :sqlite, database: "x.db" }
      hecksagon = builder.build
      expect(hecksagon.persistence).to be_nil
      expect(hecksagon.io_adapters.first.kind).to eq(:sqlite)
    end

    it "routes :memory through to persistence" do
      builder = described_class.new("App")
      silence_stderr { builder.persistence :memory }
      hecksagon = builder.build
      expect(hecksagon.persistence).to eq(type: :memory)
    end

    it "warns only once per builder" do
      builder = described_class.new("App")
      silence_stderr { builder.persistence :memory }
      expect {
        builder.persistence :sqlite, database: "x.db"
      }.not_to output.to_stderr
    end

    def silence_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
    ensure
      $stderr = original
    end
  end
end
