# frozen_string_literal: true

require "fileutils"
require_relative "../console_capture"
require "hecks/runtime/errors"

module Hecks
  module Adapters
    # Adapters of the Codebase part of the Hecks domain: the tools for working on this repository.
    module Codebase
      # The working tree a Codebase request acts on, and the one rule they all share: it is a hecks
      # checkout, a tree with `hecks.gemspec` beside `lib/`.
      #
      # The package carries `lib/` and the Rust workspace but never the gemspec, so an installed gem
      # cannot be mistaken for a checkout and answers "needs a hecks checkout" instead of globbing
      # an absent `rust/` or rewriting its own `lib/`. A request that changes files goes through
      # {#apply}: it compares each file with what it should hold, reports the drift, and writes
      # only when confirmed.
      class Tree
        # The file whose presence beside `lib/` marks a hecks checkout.
        MARKER = "hecks.gemspec"

        # What a request outside a checkout is refused with.
        NEEDS = "needs a hecks checkout"

        # The repository this file lives in.
        DEFAULT_ROOT = File.expand_path("../../../../..", __dir__)

        class << self
          # @return [String, nil] the tree to act on; this repository when nil. A spec points it
          #   at a directory that is not a checkout, so no install is needed to test the refusal.
          attr_accessor :root
        end

        # Raised when a request needs a hecks checkout and the tree is not one. It is the runtime's
        # own refusal for an unmet rule, so a query answered here reads as a refusal in the
        # launcher.
        class NeedsCheckout < Runtime::GivenNotMet; end

        # @return [String] the tree's root directory
        attr_reader :root

        # @param root [String, nil] the tree's root; {.root}, or this repository, when nil
        def initialize(root: nil)
          @root = File.expand_path(root || self.class.root || DEFAULT_ROOT)
        end

        # @return [Boolean] whether the tree is a hecks checkout
        def checkout?
          File.exist?(File.join(@root, MARKER)) && Dir.exist?(File.join(@root, "lib"))
        end

        # @return [void]
        # @raise [NeedsCheckout] "needs a hecks checkout" when the tree is not one
        def require_checkout!
          return if checkout?

          raise NeedsCheckout, "#{NEEDS}: #{MARKER} does not stand beside lib/ in #{@root}"
        end

        # @param parts [Array<String>] path segments below the root
        # @return [String] the absolute path
        def path(*parts) = File.join(@root, *parts)

        # @param absolute [String] a path inside the tree
        # @return [String] the path relative to the root
        def relative(absolute) = absolute.delete_prefix("#{@root}/")

        # Compares each file with what it should hold, and writes the differences only when
        # confirmed.
        #
        # @param files [Hash{String => String}] absolute path to the text it should hold
        # @param stale [Array<String>] absolute paths that should not exist
        # @param confirm [Boolean] whether to write; the comparison is all that happens when false
        # @return [String] what differs, and whether it was written
        def apply(files, stale: [], confirm: false)
          changes = drift(files, stale)
          return "nothing to change: #{files.size} files already hold what the language projects" if changes.empty?

          write(files, stale) if confirm
          summarize(changes, confirm)
        end

        private

        def drift(files, stale)
          changed = files.filter_map do |path, text|
            next [:new, path] unless File.exist?(path)

            [:changed, path] unless File.read(path) == text
          end
          changed + stale.select { |path| File.exist?(path) }.map { |path| [:removed, path] }
        end

        def write(files, stale)
          files.each do |path, text|
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, text)
          end
          stale.each { |path| FileUtils.rm_f(path) }
        end

        def summarize(changes, confirm)
          lines = changes.map { |kind, path| "  #{kind} #{relative(path)}" }
          head = confirm ? "wrote #{changes.size} files:" : "dry run, #{changes.size} files differ (add --confirm to write):"
          [head, *lines].join("\n")
        end
      end
    end
  end
end
