# Hecks::EventSourcing::ReadModelStore
#
# Port for read model persistence in a CQRS setup. Provides a simple
# key-value interface for projected read models. The memory adapter
# is used in tests; swap for Redis/SQL in production.
#
# == Usage
#
#   store = ReadModelStore.new
#   store.put("orders:summary", { total: 5, revenue: 100 })
#   store.get("orders:summary")  # => { total: 5, revenue: 100 }
#   store.delete("orders:summary")
#   store.clear
#
class Hecks::EventSourcing::ReadModelStore
  # @return [Hash{String => Object}] all stored read models
  attr_reader :data

  def initialize
    @data = {}
    @mutex = Mutex.new
  end

  # Store a read model by key.
  #
  # @param key [String] the read model identifier
  # @param value [Object] the projected data
  # @return [Object] the stored value
  def put(key, value)
    @mutex.synchronize { @data[key.to_s] = value }
  end

  # Retrieve a read model by key.
  #
  # @param key [String] the read model identifier
  # @return [Object, nil] the stored value or nil
  def get(key)
    @mutex.synchronize { @data[key.to_s]&.dup }
  end

  # Remove a read model by key.
  #
  # @param key [String] the read model identifier
  # @return [Object, nil] the removed value
  def delete(key)
    @mutex.synchronize { @data.delete(key.to_s) }
  end

  # Remove all stored read models.
  #
  # @return [void]
  def clear
    @mutex.synchronize { @data.clear }
  end

  # Return all keys in the store.
  #
  # @return [Array<String>] all stored keys
  def keys
    @mutex.synchronize { @data.keys.dup }
  end
end
