require "fileutils"
require_relative "workspace"

module Hecks
  module Composer
    # The domains the editor can open, on the hecksagon side: every directory under a checkout
    # that holds a bluebook, in groups, and the copy of one that the editor works on.
    #
    # A domain is opened as a scratch copy under `tmp/composer/`, so saving, the agent and Undo
    # never touch the real files. Only an id from {known} can be opened, so a request cannot name
    # a path of its own.
    module Domains
      # Where scratch copies live, relative to the checkout (it is not committed).
      SCRATCH = "tmp/composer".freeze

      # The groups the picker shows, in order, each with the ids it takes.
      GROUPS = [["Examples", %r{\Aexamples/[^/]+\z}],
                ["Stress domains", %r{\Aqa/stress_domains/[^/]+\z}],
                ["Hecks bluebooks", %r{\Alib/hecks/}],
                ["Quality control", /\Aqa\z/],
                ["Composer fixtures", %r{\Aspec/fixtures/composer/[^/]+\z}]].freeze

      # Raised when an id is not one of the known domains.
      class Unknown < ArgumentError; end

      module_function

      # @param root [String] the checkout to search
      # @return [Array<Hash>] `{id:, group:}` for each known domain, in group then id order, where
      #   `id` is the domain's directory relative to `root`
      def known(root:)
        entries = owners(root).filter_map { |id| entry_for(id) }
        entries.sort_by { |entry| [rank(entry[:group]), entry[:id]] }
      end

      # Copies a known domain's declaration files into a fresh scratch directory.
      #
      # @param root [String] the checkout
      # @param id [String] one of the ids {known} lists
      # @return [String] the scratch directory the editor should open
      # @raise [Unknown] if `id` is not a known domain
      def open(root:, id:)
        raise Unknown, "#{id.inspect} is not a domain this checkout knows" unless known?(root, id)

        scratch = File.join(root, SCRATCH, id.tr("/", "_"))
        FileUtils.rm_rf(scratch)
        FileUtils.mkdir_p(scratch)
        Workspace.copy_declarations(source(root, id), scratch)
        scratch
      end

      # @api private
      def known?(root, id) = known(root: root).any? { |entry| entry[:id] == id }

      # @api private
      def entry_for(id)
        group = GROUPS.find { |_, pattern| pattern.match?(id) }
        { id: id, group: group.first } if group
      end

      # @api private
      def rank(group) = GROUPS.index { |name, _| name == group }

      # @api private
      def owners(root)
        Dir.glob("**/*.bluebook", base: root).map { |path| owner(File.dirname(path)) }.uniq
      end

      # A `bluebook/` folder stands for the domain that holds it.
      # @api private
      def owner(dir) = File.basename(dir) == "bluebook" ? File.dirname(dir) : dir

      # Where a domain's bluebooks are: its `bluebook/` folder if it has one, else itself.
      # @api private
      def source(root, id)
        folder = File.join(root, id, "bluebook")
        File.directory?(folder) ? folder : File.join(root, id)
      end
    end
  end
end
