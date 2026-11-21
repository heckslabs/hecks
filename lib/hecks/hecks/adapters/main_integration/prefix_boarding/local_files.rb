# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    class MainIntegration
      class PrefixBoarding
        # The machine-local world and hecksagon files of a checkout (`lib/**/*.local.world`,
        # `lib/**/*.local.hecksagon`), copied into a worktree so a launcher run there reads the same
        # local stores the checkout does. Git does not carry them, so a fresh worktree has none.
        class LocalFiles
          # The globs, relative to a checkout, of the files a worktree needs.
          PATTERNS = %w[lib/**/*.local.world lib/**/*.local.hecksagon].freeze

          # @param from [String] the checkout the files are read from
          def initialize(from)
            @from = from
          end

          # @param to [String] the worktree the files are copied into, at the same relative paths
          # @return [Array<String>] the relative paths copied
          def copy_to(to)
            found.each do |relative|
              FileUtils.mkdir_p(File.dirname(File.join(to, relative)))
              FileUtils.cp(File.join(@from, relative), File.join(to, relative))
            end
          end

          private

          def found
            PATTERNS.flat_map { |pattern| Dir.glob(pattern, base: @from) }.sort
          end
        end
      end
    end
  end
end
