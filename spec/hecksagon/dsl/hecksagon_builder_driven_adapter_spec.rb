# spec/hecksagon/dsl/hecksagon_builder_driven_adapter_spec.rb
#
# Sprint 14 — contract for the quoted-name `adapter "X" do ... end` form
# that HecksagonBuilder dispatches into DrivenAdapterBuilder. Asserts the
# Ruby builder produces Structure::DrivenAdapter / DrivingAdapter IR that
# matches the shape Rust's parse_driven_adapter / parse_driving_adapter
# captures, so the parity suite stays byte-equal for the 8 sprint-14
# fixtures listed in parity/hecksagon_known_drift.txt's retirement
# comment.
#
require_relative "../spec_helper"

RSpec.describe Hecksagon::DSL::HecksagonBuilder do
  describe "#adapter \"X\" (driven-on form)" do
    it "captures driven-on handlers + dispatches into Structure::DrivenAdapter" do
      builder = described_class.new("Tools")
      builder.adapter "ShellAdapter" do
        driven on "Tools::ShellTool.BashRan" do |event|
          dispatch "Tools::TaskTool.Get",
                   id: "shell-adapter-smoke"
        end
      end
      hecksagon = builder.build

      expect(hecksagon.driven_adapters.size).to eq(1)
      adapter = hecksagon.driven_adapters.first
      expect(adapter).to be_a(Hecksagon::Structure::DrivenAdapter)
      expect(adapter.name).to eq("ShellAdapter")
      expect(adapter.handlers.size).to eq(1)
      handler = adapter.handlers.first
      expect(handler).to be_a(Hecksagon::Structure::DrivenHandler)
      expect(handler.event_ref).to eq("Tools::ShellTool.BashRan")
      expect(handler.dispatches.size).to eq(1)
      dispatch = handler.dispatches.first
      expect(dispatch.command).to eq("Tools::TaskTool.Get")
      expect(dispatch.attrs).to eq([["id", "\"shell-adapter-smoke\""]])
    end

    it "handles `|event|` block arg as a proxy that records dotted access" do
      builder = described_class.new("Tools")
      builder.adapter "CompliantAdapter" do
        driven on "Tools::ShellTool.BashRan" do |event|
          dispatch "Tools::ShellTool.BashCompleted",
                   invocation_id: event.invocation_id,
                   output: event.stdout
        end
      end
      hecksagon = builder.build

      handler = hecksagon.driven_adapters.first.handlers.first
      attrs = handler.dispatches.first.attrs
      # EventProxy.inspect returns bare token form — matching Rust's
      # raw-text capture of the dispatch line's value tokens.
      expect(attrs).to eq([
        ["invocation_id", "event.invocation_id"],
        ["output",        "event.stdout"],
      ])
    end

    it "leaves driving_adapters empty when only driven-on declared" do
      builder = described_class.new("Tools")
      builder.adapter "ShellAdapter" do
        driven on "Tools::ShellTool.BashRan" do |event|
          dispatch "Tools::TaskTool.Get", id: "smoke"
        end
      end
      hecksagon = builder.build
      expect(hecksagon.driving_adapters).to be_empty
    end
  end

  describe "#adapter \"X\" (driving-on form)" do
    it "captures driving-on handlers + dispatches into Structure::DrivingAdapter" do
      builder = described_class.new("Tools")
      builder.adapter "CronAdapter" do
        driving on cron "*/5 * * * *" do |signal|
          dispatch "Tools::TaskTool.Get",
                   id: "cron-adapter-smoke"
        end
      end
      hecksagon = builder.build

      expect(hecksagon.driving_adapters.size).to eq(1)
      adapter = hecksagon.driving_adapters.first
      expect(adapter).to be_a(Hecksagon::Structure::DrivingAdapter)
      expect(adapter.name).to eq("CronAdapter")
      handler = adapter.handlers.first
      expect(handler.kind).to eq("cron")
      expect(handler.arg).to eq("*/5 * * * *")
      expect(handler.dispatches.first.command).to eq("Tools::TaskTool.Get")
    end

    it "captures the interval kind (driving on interval \"Ns\")" do
      builder = described_class.new("Tools")
      builder.adapter "IntervalAdapter" do
        driving on interval "2s" do |signal|
          dispatch "Tools::TaskTool.Get",
                   id: "interval-adapter-smoke"
        end
      end
      hecksagon = builder.build

      handler = hecksagon.driving_adapters.first.handlers.first
      expect(handler.kind).to eq("interval")
      expect(handler.arg).to eq("2s")
      expect(handler.dispatches.first.command).to eq("Tools::TaskTool.Get")
    end
  end

  describe "tolerance for runtime-callback bodies (matches negative_callback_adapter fixture)" do
    it "swallows rt.find / bus.query top-level calls inside the handler body" do
      builder = described_class.new("Tools")
      expect {
        builder.adapter "CallbackAdapter" do
          driven on "Tools::ShellTool.BashRan" do |event|
            shell_tool = rt.find("Tools::ShellTool", event.invocation_id)
            dispatch "Tools::ShellTool.BashCompleted",
                     invocation_id: event.invocation_id,
                     output: shell_tool.stdout
          end
        end
      }.not_to raise_error
      handler = builder.build.driven_adapters.first.handlers.first
      expect(handler.dispatches.first.attrs.map(&:first)).to eq(%w[invocation_id output])
    end
  end

  describe "extra one-liner kwargs (idempotent: / dedup_by:) on the quoted-name form" do
    it "silently ignores them (matches Rust's header-only parse)" do
      builder = described_class.new("Tools")
      expect {
        builder.adapter "OptInIdempotentAdapter", idempotent: true, dedup_by: :invocation_id do
          driven on "Tools::ShellTool.BashRan" do |event|
            dispatch "Tools::ShellTool.BashCompleted",
                     invocation_id: event.invocation_id
          end
        end
      }.not_to raise_error
      expect(builder.build.driven_adapters.first.name).to eq("OptInIdempotentAdapter")
    end
  end
end
