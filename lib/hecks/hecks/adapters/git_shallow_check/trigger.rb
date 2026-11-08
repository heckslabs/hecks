# frozen_string_literal: true

module Hecks
  module Adapters
    class GitShallowCheck
      # Decides from a branch's changed paths whether CI's failing checks are worth a clone.
      #
      # A path counts when a spec in the check set can read it: a bluebook, hecksagon, world,
      # behaviors or adapter declaration, Ruby under `lib/` or `spec/` (commands and generators
      # included), the launcher in `exe/` and the bundle. Docs and everything else add nothing.
      module Trigger
        # The paths that start the check.
        WATCHED = %r{\.(bluebook|hecksagon|world|behaviors|adapter)\z|\A(lib|spec)/.*\.rb\z|\Aexe/|\AGemfile(\.lock)?\z}

        # @param paths [Array<String>] repository-relative changed paths
        # @return [Array<String>] the paths the check set reads
        def self.watched(paths) = paths.grep(WATCHED)

        # @param paths [Array<String>] repository-relative changed paths
        # @param domains [Array<String>] absolute fuzzable domain directories of a checkout
        # @param root [String] that checkout
        # @return [Array<String>] the domains holding a changed path, as `fuzz_run.fuzz!` takes them
        def self.fuzzed(paths, domains, root)
          domains.select { |dir| paths.any? { |path| File.join(root, path).start_with?("#{dir}/") } }
        end
      end
    end
  end
end
