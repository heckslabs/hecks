# Hecks::Registry
#
# Hash-backed registry for named resources. All keys are sym-coerced.
# Replaces the lazy_registry + module ivar pattern with a proper object.
#
#   targets = Hecks::Registry.new
#   targets.register(:ruby) { |domain| build(domain) }
#   targets[:ruby]  # => #<Proc>
#   targets.keys    # => [:ruby]
#
module Hecks
  # Hecks::Registry
  #
  # Hash-backed registry for named resources with symbol-coerced keys and Enumerable support.
  #
  class Registry
    include Enumerable

    def initialize(initial = {})
      @store = initial.transform_keys(&:to_sym)
    end

    def register(key, value)
      @store[key.to_sym] = value
    end

    def [](key)
      @store[key.to_sym]
    end

    def []=(key, value)
      @store[key.to_sym] = value
    end

    def delete(key)
      @store.delete(key.to_sym)
    end

    def keys
      @store.keys
    end

    def each(&block)
      @store.each(&block)
    end

    def each_value(&block)
      @store.each_value(&block)
    end

    def values
      @store.values
    end

    def flat_map(&block)
      @store.flat_map(&block)
    end

    def include?(key)
      @store.include?(key.to_sym)
    end

    def key?(key)
      @store.key?(key.to_sym)
    end

    def empty?
      @store.empty?
    end

    def all
      @store.dup
    end
  end
end
