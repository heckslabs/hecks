module Hecks
  module Bluebook
    module MetaValidator
      module VerdictCache
        # The verdict file the process reads (its own, else the one a packaged gem ships) and the
        # Ruby series that file is valid for.
        module Prebuilt
          # The Ruby the judging code ran on, to the minor version: a patch release changes neither
          # a verdict nor the encoding of one, so a cache built on one patch serves the others.
          #
          # @return [String] such as `ruby-3.3`
          def ruby_series = "#{RUBY_ENGINE}-#{RUBY_VERSION[/\A\d+\.\d+/]}"

          # The file the gem ships for the current code's verdicts, when it ships one.
          #
          # @return [String] an absolute path
          def prebuilt_path = Hecks::CacheDir.prebuilt(File.basename(path))

          # Reads and decodes the current code's file: the user's own, else the gem's prebuilt one.
          #
          # @return [Hash{String => Hash}] entries, or `{}` on any problem
          def read
            own = path
            return read_file(own) if File.file?(own) && trusted?(own)

            File.file?(prebuilt_path) ? read_file(prebuilt_path) : {}
          end

          # @param file [String] a verdict file already trusted
          # @return [Hash{String => Hash}] its entries, or `{}` on any problem
          def read_file(file)
            doc = JSON.parse(File.binread(file), max_nesting: false)
            return {} unless doc.is_a?(Hash) && doc["format"] == FORMAT

            decoded = decode(doc["entries"])
            well_formed?(decoded) ? decoded : {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
