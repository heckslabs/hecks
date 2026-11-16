# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"
require_relative "../../support/shallow_repo"

# A landing's shallow check holds the checkout's claim and the heavy-job place for its whole run,
# so it never runs beside another landing's gate or check.
RSpec.describe Hecks::Adapters::GitShallowCheck, "#shallow_check places" do
  include ShallowRepo

  let(:place_dir) { File.join(dir, "heavy-jobs") }
  let!(:gate) { gate_holding }

  def claim(pid, words = %w[Landing.carry!])
    Hecks::Adapters::LandingClaim.new(dir: File.join(dir, "claims"), words: words, pid: pid)
  end

  # Takes the one heavy-job place as a running gate would.
  def gate_holding
    FileUtils.mkdir_p(place_dir)
    File.new(File.join(place_dir, "slot-0.lock"), File::CREAT | File::RDWR).tap { |file| file.flock(File::LOCK_EX) }
  end

  # Heavy-job places with a cap of one that let the gate go on the first wait.
  def one_place
    lambda do |_root, job, &block|
      Hecks::Adapters::Codebase::HeavySlots.new(cap: 1, dir: place_dir, base: {}, err: StringIO.new,
                                                clock: (0..20).each.method(:next).to_proc,
                                                pause: ->(_seconds) { gate.close }).hold(job, &block)
    end
  end

  # An impacted run that records whether the gate had let its place go when the specs ran.
  def impacted(seen)
    ->(_paths, _onto) { Hecks::Adapters::GitShallowCheck::ImpactedRun::Outcome.new([seen << gate.closed?], [], 1, 1) }
  end

  def checked(**tune)
    build_repo("docs/guide.md")
    shallow(command: ["false"], claim: claim(7), **tune)
  end

  it "runs its specs only after a gate holding the only heavy-job place lets it go" do
    seen = []
    checked(impacted: impacted(seen), slots: one_place)
    expect(seen).to eq([true])
  end

  it "names the wait for the heavy-job place at the top of its report" do
    answer = checked(impacted: impacted([]), slots: one_place)
    expect(answer[:report][:value]).to start_with("waited 2 s for a heavy-job slot (1 of 1 taken); ")
  end

  it "is refused while another landing of the checkout holds its claim, naming it" do
    build_repo("docs/guide.md")
    claim(4242).hold(tree) do
      expect { shallow(command: ["false"], claim: claim(7, []), impacted: impacted([])) }
        .to raise_error(failure, /landing in flight: .*pid 4242 \(Landing\.carry!\)/)
    end
  end
end
