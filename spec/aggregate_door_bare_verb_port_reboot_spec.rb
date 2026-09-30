require "spec_helper"
require "tmpdir"
require_relative "support/bare_port_reboot_domain"

# Bug (found sweeping lifeadelics/lifeadelics, an external hecks-gem consumer, seed 1):
# a bare-verb port declaration (`port "x" do verb "y" end`) makes `DomainPortBuilder#build`
# return a plain `Bluebook::Port` (verb/signal/answers, no `operations`), not a `DomainPort`.
# `DSL::BindingProxy#port` and `HecksagonBuilder#port_impl` both guard with
# `built.is_a?(Port)` before touching `.operations`; `Doors::RubyDoor::AggregateDoor#port` —
# reached once the aggregate's Ruby facade constant already exists, e.g. the same domain
# booted a second time in one process — did not, and crashed with a raw `NoMethodError`
# instead of a declared `Bluebook::DSL::Malformed`.
#
# `Hecks::Fuzzing::SequenceGenerator.generate` boots a domain once to build its catalog, then
# `Replay.call` boots it again — the identical double-boot shape. Reproduced here with a
# minimal fixture domain, independent of lifeadelics's own bluebook.
RSpec.describe "a bare-verb driven port on a domain booted twice in one process" do
  it "does not crash AggregateDoor#port with a raw NoMethodError" do
    Dir.mktmpdir("bare-port-reboot-") do |dir|
      BarePortRebootDomain.boot(dir)

      expect { BarePortRebootDomain.boot(dir) }.not_to raise_error
    end
  end
end
