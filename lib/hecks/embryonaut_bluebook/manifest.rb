require "json"
require_relative "lock"

module Hecks
  module EmbryonautBluebook
    # Checks a project's vendored packages against their `bluebook.lock` files and describes
    # them as data: the manifest a client image carries to say which bluebooks it holds.
    #
    #     { "built_from" => { "commit" => "<project commit>", "dirty" => false },
    #       "bluebooks"  => { "payments" => { "version" => "1.0.0", "tag" => "payments-v1.0.0",
    #                                          "commit" => "<sha>", "digest" => "<sha256>",
    #                                          "shape"  => ["Payments d33c23"] } } }
    #
    # There is no timestamp: the same inputs give the same manifest. The digest is `Lock.digest_of`,
    # the one implementation `Vendor` also writes locks with.
    class Manifest
      # The lock fields every package must carry besides its shape.
      FIELDS = %w[package version tag commit digest].freeze

      # The fields a package's manifest entry repeats from its lock.
      ENTRY = %w[version tag commit digest].freeze

      # A refusal: every way the vendored packages disagree with their locks, one per line.
      class Mismatch < StandardError
        # @return [Array<String>] one sentence per disagreement
        attr_reader :problems

        # @param problems [Array<String>] the disagreements found
        def initialize(problems)
          @problems = problems
          super(problems.map { |problem| "FAIL #{problem}" }.join("\n"))
        end
      end

      # @param root [String] the project directory holding `vendor/embryonaut_bluebooks/`
      # @param built_from [Hash{String => Object}, nil] the project's own commit and whether the
      #   tree is dirty; left out of the manifest when nil
      def initialize(root, built_from: nil)
        @root = root
        @built_from = built_from
      end

      # Checks every vendored package and describes them.
      #
      # @return [Hash{String => Object}] the manifest
      # @raise [Mismatch] when any package disagrees with its lock
      def call
        problems = []
        packages = names.to_h { |name| [name, entry(name, problems)] }.compact
        raise Mismatch, problems unless problems.empty?

        { "built_from" => @built_from, "bluebooks" => packages }.compact
      end

      # The manifest as the text a label or file holds: keys sorted, two-space indent.
      #
      # @return [String] JSON ending in a newline
      def to_json_text
        "#{JSON.pretty_generate(sort(call))}\n"
      end

      private

      def vendor_dir = File.join(@root, "vendor", "embryonaut_bluebooks")

      def names
        return [] unless File.directory?(vendor_dir)

        Dir.children(vendor_dir).sort.select { |name| File.directory?(File.join(vendor_dir, name)) }
      end

      # One package's manifest entry, or nil (its reasons added to `problems`) when it has no lock.
      def entry(name, problems)
        dir  = File.join(vendor_dir, name)
        path = File.join(dir, "bluebook.lock")
        unless File.exist?(path)
          problems << "#{name}: no bluebook.lock (hecks package.vendor #{name}@<version>)"
          return nil
        end

        lock = Lock.read(path)
        judge(name, dir, lock, problems)
        lock.to_h.transform_keys(&:to_s).slice(*ENTRY).merge("shape" => Array(lock.shape))
      end

      def judge(name, dir, lock, problems)
        FIELDS.each { |field| problems << "#{name}: bluebook.lock has no #{field}" if blank?(lock[field.to_sym]) }
        problems << "#{name}: bluebook.lock names package #{lock.package}" if lock.package && lock.package != name
        problems << "#{name}: bluebook.lock has no shape" if Array(lock.shape).empty?
        judge_release(name, lock, problems)
        actual = Lock.digest_of(File.join(dir, "bluebook"))
        return if actual == lock.digest

        problems << "#{name}: vendored files hash to #{(actual || 'nothing')[0, 12]}, but bluebook.lock says " \
                    "#{(lock.digest || '?')[0, 12]} (edited by hand, or re-vendored without its lock?)"
      end

      # The tag of a release is `<package>-v<version>`; a lock saying otherwise was edited.
      def judge_release(name, lock, problems)
        return if blank?(lock.tag) || blank?(lock.version)
        return if lock.tag == "#{name}-v#{lock.version}"

        problems << "#{name}: bluebook.lock tag #{lock.tag} is not #{name}-v#{lock.version}"
      end

      def blank?(value) = value.nil? || value.to_s.empty?

      def sort(value)
        case value
        when Hash  then value.sort.to_h { |key, inner| [key, sort(inner)] }
        when Array then value.map { |inner| sort(inner) }
        else value
        end
      end
    end
  end
end
