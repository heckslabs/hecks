# frozen_string_literal: true

# The registries and reads the store's specs ask of it.
module RegistryStoreSpecWorld
  def book = Struct.new(:aggregates).new([Struct.new(:hecks_name).new("Work")])

  def registry
    book = self.book
    repository = Struct.new(:all).new([1])
    Class.new do
      define_method(:bluebook) { |_domain| book }
      define_method(:repository) { |*| repository }
    end.new
  end

  # A registry that counts each load of the aggregate.
  def counting
    counted = registry
    loads_seen = loads
    counted.define_singleton_method(:repository) { |*| Struct.new(:all).new(loads_seen.push(1) && [1]) }
    counted
  end

  def read_at(*seconds, registry: counting)
    store = described_class.new(registry: registry, clock: -> { time.first })
    seconds.each do |at|
      time[0] = at
      store.records("Tickets", "Work")
    rescue StandardError
      nil
    end
  end

  # A registry whose load takes eight seconds on the spec's clock, or fails when `failing`.
  def slow(failing: false)
    clock = time
    slowed = counting
    loads_seen = loads
    slowed.define_singleton_method(:repository) do |*|
      clock[0] += 8.0
      loads_seen.push(1)
      raise "disk" if failing

      Struct.new(:all).new([1])
    end
    slowed
  end
end
