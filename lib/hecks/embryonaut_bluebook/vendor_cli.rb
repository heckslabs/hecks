require "optparse"
require_relative "vendor"

module Hecks
  module EmbryonautBluebook
    # The command line behind `bin/vendor_bluebook`; lives in the gem so a
    # consuming project reaches it through its own bundle, no script to copy.
    #
    #     vendor_bluebook <package>[@<version-or-commit>] [--from path] [--root path]
    module VendorCli
      USAGE = "usage: vendor_bluebook <package>[@<version-or-commit>] [--from PATH] [--root PATH]".freeze

      # Runs the command and reports on the given streams.
      #
      # @param argv [Array<String>] the command-line arguments
      # @param env [Hash{String => String}] the environment
      # @param out [IO] where the report goes
      # @param err [IO] where a refusal goes
      # @param root [String] the default project root
      # @return [Integer] the exit status, 0 when the package was vendored
      def self.run(argv, env: ENV, out: $stdout, err: $stderr, root: Dir.pwd)
        options = { from: env["EMBRYONAUT_BLUEBOOKS_SRC"], root: root }
        spec = parse(argv, options)
        return usage(err) unless spec && options[:from]

        name, _, ref = spec.partition("@")
        result = Vendor.new(name, from: options[:from], root: options[:root], ref: ref.empty? ? nil : ref,
                                  allow_downgrade: env["ALLOW_DOWNGRADE"] == "1").call
        report(result, options[:from], out)
        0
      rescue Vendoring::Error, OptionParser::ParseError => e
        err.puts(e.message)
        1
      end

      # nil unless argv held exactly one positional argument.
      def self.parse(argv, options)
        parser = OptionParser.new
        parser.on("--from PATH") { |path| options[:from] = path }
        parser.on("--root PATH") { |path| options[:root] = path }
        rest = parser.parse(argv)
        rest.first if rest.length == 1
      end

      def self.usage(err)
        err.puts(USAGE)
        2
      end

      def self.report(result, from, out)
        label = result.release? ? "#{result.version} (#{result.tag}, #{result.commit[0, 7]})" : result.commit[0, 12]
        out.puts("Vendored embryonaut_bluebooks/#{result.package} #{label} from #{from} into #{result.dir}")
        out.puts(shape_line(result))
      end

      # The shape label tells a re-vendor that only moved the pin apart from one
      # that will mint a new era on the next deploy.
      def self.shape_line(result)
        now = result.shape.join(" ")
        if result.previous_shape.nil?
          "Shape: #{now} (no earlier vendored copy to compare against)"
        elsif result.shape_changed?
          "SHAPE CHANGED: the next deploy mints a new era; add its translation edge first.\n  " \
            "before: #{result.previous_shape.join(' ')}\n  after:  #{now}"
        else
          "Shape unchanged: #{now}. No new era on deploy."
        end
      end

      private_class_method :parse, :usage, :report, :shape_line
    end
  end
end
