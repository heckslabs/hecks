require "hecks"

# HecksCqrs
#
# CQRS (Command Query Responsibility Segregation) support for Hecks domains.
# Enables named persistence connections for read/write separation. Commands
# route to the +:write+ connection, queries to the +:read+ connection.
# Registers with the Hecks connection registry so domains can declare
# multiple named adapters in their boot block.
#
# A domain has CQRS active when more than one named persist connection
# exists in its connections hash. This module provides introspection
# methods to check CQRS status and retrieve individual connection configs.
#
#   CatsDomain.boot do
#     persist_to :write, :sqlite
#     persist_to :read, :sqlite, database: "read.db"
#   end
#
#   # Access named connections:
#   CatsDomain.connections[:persist][:write]
#   # => { type: :sqlite }
#   CatsDomain.connections[:persist][:read]
#   # => { type: :sqlite, database: "read.db" }
#

module HecksCqrs
  VERSION = "2026.03.24.1"

  # Check whether a domain module has CQRS connections configured.
  # Returns true when more than one named persist connection exists,
  # indicating separate read and write paths.
  #
  # @param mod [Module] a domain module that includes BluebookConnections;
  #   must respond to +connections+ returning a Hash with a +:persist+ key
  # @return [Boolean] true if the module has multiple persist connections
  def self.active?(mod)
    return false unless mod.respond_to?(:connections)

    persist = mod.connections[:persist]
    persist.is_a?(Hash) && persist.size > 1
  end

  # Return the adapter configuration hash for a named connection, or nil
  # if the connection does not exist or the module has no connections.
  #
  # @param mod [Module] a domain module that includes BluebookConnections
  # @param name [Symbol] connection name, typically +:write+ or +:read+,
  #   but can also be +:default+ or any custom name
  # @return [Hash, nil] the adapter configuration hash (e.g.
  #   +{ type: :sqlite, database: "read.db" }+), or nil if not found
  def self.connection_for(mod, name)
    return nil unless mod.respond_to?(:connections)

    persist = mod.connections[:persist]
    persist[name] if persist.is_a?(Hash)
  end
end

# Register with Hecks connection registry if available
if defined?(Hecks) && Hecks.respond_to?(:extension_registry)
  Hecks.extension_registry[:cqrs] = HecksCqrs
end
