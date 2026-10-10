require "tmpdir"
require "fileutils"

# A minimal domain whose aggregate declares a bare-verb driven port (`verb "..."`, no
# operations) — the shape `DomainPortBuilder#build` turns into a plain `Bluebook::Port`
# rather than a `DomainPort`. `DSL::BindingProxy#port` (hit on a domain's first in-process
# boot, before its aggregate facade constant exists) and `HecksagonBuilder#port_impl` both
# guard for that shape with `built.is_a?(Port)`. `Adapters::Driving::Ruby::AggregateModule`'s own
# `:port` singleton method — hit once the aggregate's facade constant already exists, e.g.
# a domain booted twice in the same process — does not, and calls `.operations` on the bare
# `Port` unconditionally.
module BarePortRebootDomain
  BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "BarePortReboot" do
      vision "One aggregate with a bare-verb driven port, rebooted in-process."
      core

      aggregate "Widget" do
        description "A minimal aggregate that also declares an outbound bare-verb port."
        identified_by :label
        attribute :label, WidgetLabel

        value_object "WidgetLabel", String

        command "Make" do
          goal "Make a widget"
          attribute :label, WidgetLabel
          sets :label
          emits "Made"
        end
      end
    end
  BLUEBOOK

  HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "BarePortReboot" do
      BarePortReboot::Widget.persisted_by("Memory")

      BarePortReboot::Widget.port "notifies" do
        verb "notified_by"
      end
    end
  HECKSAGON

  # Writes the domain into `dir` (creating `dir/bluebook` if needed) and boots it. Calling
  # this twice with the same `dir` boots the identical domain path a second time in the
  # same process — the aggregate's Ruby facade constant already exists on the second call,
  # which is what routes `.port` through `AggregateModule` instead of `DSL::BindingProxy`.
  def self.boot(dir)
    bluebook_dir = File.join(dir, "bluebook")
    FileUtils.mkdir_p(bluebook_dir)
    File.write(File.join(bluebook_dir, "bare_port_reboot.bluebook"), BLUEBOOK)
    File.write(File.join(bluebook_dir, "bare_port_reboot.hecksagon"), HECKSAGON)
    Hecks::Runtime.boot(dir)
  end
end
