# frozen_string_literal: true

# A log the board reads from a position: the events, and every position it was asked from.
class TailedLog
  Event = Struct.new(:name, :occurred_at)

  attr_reader :asked
  attr_accessor :events, :failing

  def initialize(events = [])
    @events = events
    @asked = []
    @failing = nil
  end

  def event_count(*)
    raise Hecks::Adapters::PipelineBoard::Unavailable, "count" if failing == :count

    events.size
  end

  def events_past(_domain, _name, position)
    raise Hecks::Adapters::PipelineBoard::Unavailable, "read" if failing == :read

    asked << position
    events.drop(position)
  end

  def add(name, at) = events.push(Event.new(name, at))
end

# What {Hecks::Adapters::PipelineBoard::FinishedTimes} needs of its host.
class TimesHost
  include Hecks::Adapters::PipelineBoard::FinishedTimes

  def initialize(live)
    @live = live
    @work_lock = Mutex.new
  end

  def swap(live) = @live = live
end
