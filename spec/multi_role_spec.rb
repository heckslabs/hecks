require "spec_helper"
require "fileutils"
require "tmpdir"

# Who may run a multi-role command is in examples/multi_role/bluebook/multi_role.behaviors. What
# stays here is what `expect` cannot say: the IR keeps `role` as the first and gains `roles` only
# when there is more than one, and a bluebook that names a role twice does not boot.
RSpec.describe "a command run by several roles" do
  DESK_BLUEBOOK = File.join(InMemoryDomain::ROOT, "examples/multi_role/bluebook/multi_role.bluebook")

  let(:scratch) { Dir.mktmpdir }
  let(:runtime) { Hecks.boot_files([DESK_BLUEBOOK], install_driving: false) }

  after { FileUtils.remove_entry(scratch) }

  def boot_text(text)
    path = File.join(scratch, "desk.bluebook")
    File.write(path, text)
    Hecks.boot_files([path], install_driving: false)
  end

  def command_ir(name)
    ir = Hecks::Projector::Exporter.call(runtime.registry).fetch("Desk")
    ir.fetch(:aggregates).first.fetch(:commands).find { |command| command[:name] == name }
  end

  it "keeps the first as `role` and lists every role under `roles`" do
    expect(command_ir("Open")).to include(role: "Customer", roles: ["Customer", "Sales Rep"])
  end

  it "leaves `roles` out of the IR of a command with one role" do
    expect(command_ir("Close")).to include(role: "Agent").and(satisfy { |ir| !ir.key?(:roles) })
  end

  it "refuses naming a role twice" do
    text = File.read(DESK_BLUEBOOK).sub(/^ +role "Customer", "Sales Rep"$/, '      role "Customer", "Customer"')

    expect { boot_text(text) }.to raise_error(StandardError, /role/)
  end

  it "refuses declaring roles twice" do
    text = File.read(DESK_BLUEBOOK).sub(/^ +role "Customer", "Sales Rep"$/, %(      role "Customer"\n      role "Sales Rep"))

    expect { boot_text(text) }.to raise_error(StandardError, /role/)
  end
end
