require_relative "project_discovery"
require_relative "project_register"

module Hecks
  module Bluebook
    # Boots each discovered directory and feeds its declarations into the project register.
    # Discovery and FQN registration are separate objects so either works without booting domains.
    class ProjectLoader
      Entry          = ProjectRegister::Entry
      DuplicateFqn   = ProjectRegister::DuplicateFqn
      MissingRealm   = ProjectRegister::MissingRealm
      LatestMismatch = ProjectRegister::LatestMismatch

      attr_reader :root, :discovery, :register

      def self.load(root) = new(root).load

      def initialize(root, discovery: ProjectDiscovery.new(root), register: ProjectRegister.new)
        @root      = File.expand_path(root)
        @discovery = discovery
        @register  = register
      end

      # Errors raised by `ProjectRegister#register` propagate.
      def load
        discovery.bluebook_directories.each do |directory|
          runtime = Runtime.boot(directory)
          register.register(runtime.registry.bluebooks.values, runtime.registry, runtime, directory)
        end
        self
      end

      def entries = register.entries

      def fetch(address) = register.fetch(address)

      def include?(address) = register.include?(address)

      def commands = register.commands

      def queries  = register.queries
    end
  end
end
