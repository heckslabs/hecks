# frozen_string_literal: true

module Hecks
  module Tools
    module GateMemo
      # The gitignored files a copy keeps for itself, which decide where a booted domain stores and
      # so what a check that boots it sees (`FolderOverlay`): local worlds and hecksagons beside a
      # domain or in the working directory, and the `local` environment. Git ignores them, so the
      # memo's `owned` list leaves them out; a check that boots a domain reads them from disk, or a
      # green on one copy's database would be reused on a copy that names another.
      module LocalFiles
        # Globs under the checkout.
        GLOBS = %w[lib/**/*.local.hecksagon lib/**/*.local.world examples/**/*.local.hecksagon
                   examples/**/*.local.world qa/**/*.local.hecksagon qa/**/*.local.world
                   *.local.hecksagon *.local.world environments/local.hecksagon
                   environments/local.world].freeze

        # The checks that boot a domain, so read its local files.
        BOOTING = %w[rspec fuzzing query_agreement engine_agreement model_check].freeze

        module_function

        # @param root [String] the checkout
        # @return [Array<String>] the local world and hecksagon files on disk, git-ignored or not,
        #   relative to the checkout and sorted
        def files(root)
          found = GLOBS.flat_map { |glob| Dir.glob(glob, base: root) }
          found.uniq.select { |rel| File.file?(File.join(root, rel)) }.sort
        end
      end
    end
  end
end
