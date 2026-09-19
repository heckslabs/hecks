require_relative "project_discovery"
require_relative "project_register"

module Hecks
  module Bluebook
    # Boots each discovered directory and feeds its declarations into the
    # deterministic project register. Discovery and FQN registration live in
    # their own objects so either can be used without executing domains.
    class ProjectLoader
      Entry          = ProjectRegister::Entry
      DuplicateFqn   = ProjectRegister::DuplicateFqn
      MissingRealm   = ProjectRegister::MissingRealm
      LatestMismatch = ProjectRegister::LatestMismatch

      attr_reader :root, :discovery, :register

      # Discovers and loads every domain under `root` in one call.
      #
      # @param root [String] the directory to search under
      # @return [Bluebook::ProjectLoader] the loader, with every discovered domain
      #   booted and registered
      def self.load(root) = new(root).load

      # @param root [String] the directory to search under
      # @param discovery [Bluebook::ProjectDiscovery] the discovery this loader walks
      #   `root` with
      # @param register [Bluebook::ProjectRegister] the register booted domains are
      #   fed into
      def initialize(root, discovery: ProjectDiscovery.new(root), register: ProjectRegister.new)
        @root      = File.expand_path(root)
        @discovery = discovery
        @register  = register
      end

      # Boots every domain `discovery` finds under `root` and registers its declarations.
      #
      # @return [Bluebook::ProjectLoader] self
      # @raise [Bluebook::ProjectRegister::MissingRealm] see `ProjectRegister#register`
      # @raise [Bluebook::ProjectRegister::LatestMismatch] see `ProjectRegister#register`
      # @raise [Bluebook::ProjectRegister::DuplicateFqn] see `ProjectRegister#register`
      # @raise [Runtime::WiringError] see `ProjectRegister#register`
      def load
        discovery.bluebook_directories.each do |directory|
          runtime = Runtime.boot(directory)
          register.register(runtime.registry.bluebooks.values, runtime.registry, runtime, directory)
        end
        self
      end

      # Lists every registered entry.
      #
      # @return [Hash{String => Bluebook::ProjectRegister::Entry}] every registered
      #   entry, keyed by its FQN
      def entries = register.entries

      # Finds a registered entry by its fully-qualified verb.
      #
      # @param address [String, #to_s] the FQN to look up
      # @return [Bluebook::ProjectRegister::Entry] the entry registered under `address`
      # @raise [KeyError] if no entry is registered under `address`
      def fetch(address) = register.fetch(address)

      # Says whether an entry is registered under an address.
      #
      # @param address [String, #to_s] the FQN to check
      # @return [Boolean] whether an entry is registered under `address`
      def include?(address) = register.include?(address)

      # Lists every registered command entry.
      #
      # @return [Array<Bluebook::ProjectRegister::Entry>] every registered command entry
      def commands = register.commands

      # Lists every registered query entry.
      #
      # @return [Array<Bluebook::ProjectRegister::Entry>] every registered query entry
      def queries  = register.queries
    end
  end
end
