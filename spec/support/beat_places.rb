# frozen_string_literal: true

require "tmpdir"
require "hecks/hecks/adapters/beating"

# Beats of the clock against the Delegate domain in Memory, with the `Beating` port's place
# kept in a temporary directory and, when asked, held by another process.
module BeatPlaces
  Beating = Hecks::Adapters::Beating

  # A child process that holds the place the way a running beat does, until it is killed.
  #
  # @param dir [String] the place's directory
  # @return [Integer] the child's pid, once it holds the place
  def hold_place(dir)
    ready, writer = IO.pipe
    code = "require 'hecks/hecks/adapters/beating'; " \
           "Hecks::Adapters::Beating.new(settings: { dir: ARGV[0] }).take; puts 'held'; $stdout.flush; sleep"
    pid = Process.spawn(RbConfig.ruby, "-Ilib", "-e", code, dir, out: writer)
    writer.close
    ready.gets
    pid
  end

  # @param dir [String] the place's directory
  # @param beat [String] the beat's key
  # @return [Array<String>] the events the beat recorded, in order
  def beat_names(dir, beat)
    registry = boot_hecks_in_memory(File.expand_path("../../lib/hecks/hecks", __dir__)).registry
    BeatPlaceDefault.dir = dir
    # A thread of its own: a launcher runs the spec inside its own reactions, and only the
    # outermost dispatch of a thread settles a beat's timings.
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) {}) do
      Thread.new do
        Hecks::Runtime::Asking.with(registry) do
          Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: beat })
        end
      end.value
    end
    registry.event_log.map(&:name)
  end

  # Beats while another process holds the place, then kills that process.
  #
  # @return [Hash] `names:` the events, `seconds:` how long the beat took, `pid:` the holder's and
  #   `refusal:` the message the place gave
  def beat_against_holder(dir)
    pid = hold_place(dir)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    names = beat_names(dir, "beat-held")
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    { names: names, seconds: seconds, pid: pid, refusal: refusal_of(dir) }.tap { kill(pid) }
  end

  # @return [Array<String>] the events of a beat made after a holder of the place was killed
  def beat_after_holder_killed(dir)
    kill(hold_place(dir))
    beat_names(dir, "beat-free")
  end

  # The place over a registry, with a measure that only notes what it was told.
  #
  # @return [Hash] `place:` the place, `recorded:` the `[beat, steps]` pairs its measure was
  #   called with
  def measuring_place(dir)
    recorded = []
    measure = ->(beat, steps) { recorded << [beat, steps] }
    { place: Beating.new(registry: Object.new, settings: { dir: dir, measure: measure }), recorded: recorded }
  end

  # @param place [Hecks::Adapters::Beating] a place over a registry
  # @return [Array<#call>] the listeners a beat taken at the place asked to have called when its
  #   reactions end (asked of a thread of its own, as a beat's are)
  def listeners_after_taking(place)
    Thread.new do
      place.take(beat: { value: "beat-1" })
      Hecks::Runtime::PolicyInterpreter::Timing.take_listeners
    end.value
  end

  def refusal_of(dir)
    Beating.new(settings: { dir: dir }).take
    ""
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  def kill(pid)
    Process.kill("KILL", pid)
    Process.wait(pid)
  end

  def clean_place(dir)
    Beating.held&.close
    Beating.held = nil
    BeatPlaceDefault.dir = nil
    FileUtils.rm_rf(dir)
  end
end
