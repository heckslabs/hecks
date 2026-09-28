require "spec_helper"
require "tmpdir"
require_relative "support/bare_port_reboot_domain"

# BUG (found sweeping lifeadelics/lifeadelics, an external hecks-gem consumer, seed 1):
# lifeadelics declares `Lifeadelics::Registration.port "checkout" do verb "opened_by" end`
# on its hecksagon — a bare-verb driven port. `DomainPortBuilder#build` turns that shape into
# a plain `Bluebook::Port` (verb/signal/answers, no `operations`), not a `DomainPort`.
#
# Two of the three call sites that dispatch to `.port` on a bare `Domain::Aggregate` constant
# guard for this: `DSL::BindingProxy#port` (hit before the aggregate's facade constant
# exists) and `HecksagonBuilder#port_impl` (root-level ports) both check
# `built.is_a?(Port)` before touching `.operations`. `Facade::Surface::AggregateDoor`'s own
# `:port` singleton method — hit once an aggregate's Ruby facade constant already exists,
# e.g. the SAME domain booted a second time in one process — does not, and calls
# `domain_port.operations` unconditionally, crashing with a raw `NoMethodError` instead of
# a declared `Bluebook::DSL::Malformed`.
#
# `Hecks::Fuzzing::SequenceGenerator.generate` boots a domain once to build its catalog, then
# `Hecks::Fuzzing::Replay.call` boots it again to run the generated steps — two in-process
# boots of the identical path, exactly the shape that reaches `AggregateDoor#port` instead of
# `BindingProxy#port`. Any domain with a bare-verb port declared this way hits this on its
# second boot, regardless of what it otherwise does — reproduced here with a two-line
# fixture domain, independent of lifeadelics's own bluebook.
RSpec.describe "a bare-verb driven port on a domain booted twice in one process" do
  it "does not crash AggregateDoor#port with a raw NoMethodError" do
    Dir.mktmpdir("bare-port-reboot-") do |dir|
      BarePortRebootDomain.boot(dir)

      expect { BarePortRebootDomain.boot(dir) }.not_to raise_error
    end
  end
end
