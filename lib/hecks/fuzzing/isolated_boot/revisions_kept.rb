module Hecks
  module Fuzzing
    module IsolatedBoot
      # Keeps a copied domain on the revision layout: every hecksagon in the copy declares
      # `revisions true`, so its Postgres bind boots as the revision store (ADR 0182).
      module RevisionsKept
        REVISIONS_LINE = /^\s*revisions\s+true\b/
        HECKSAGON_OPEN = /^(\s*Hecks\.hecksagon .*? do\n)/

        # Adds `revisions true` to each hecksagon in `copy` that does not already declare it.
        #
        # @param copy [String] the copied domain's root directory
        # @return [void]
        def self.keep!(copy)
          Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |path|
            text = File.read(path)
            next if text.match?(REVISIONS_LINE)

            File.write(path, text.sub(HECKSAGON_OPEN) { "#{Regexp.last_match(1)}  revisions true\n" })
          end
        end

        # Removes `revisions` from each hecksagon in `copy`, so a plain Postgres boot keeps the
        # table layout.
        #
        # @param copy [String] the copied domain's root directory
        # @return [void]
        def self.drop!(copy)
          Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |path|
            File.write(path, File.read(path).gsub(REVISIONS_LINE, ""))
          end
        end
      end
    end
  end
end
