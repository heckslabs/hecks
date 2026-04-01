# Hecks::DomainVersioning
#
# Manages domain interface version snapshots. Snapshots are copies of the
# domain DSL file stored in db/hecks_versions/ with a metadata header.
# Supports tagging, listing, loading, and diffing version snapshots.
#
#   Hecks::DomainVersioning.tag("2.1.0", domain, base_dir: Dir.pwd)
#   versions = Hecks::DomainVersioning.log(base_dir: Dir.pwd)
#   domain   = Hecks::DomainVersioning.load_version("2.1.0", base_dir: Dir.pwd)
#
require_relative "domain_versioning/breaking_classifier"

module Hecks
  module DomainVersioning
    VERSIONS_DIR = "db/hecks_versions"

    # Tag the current domain as a named version snapshot.
    #
    # @param version [String] semantic version label (e.g. "2.1.0")
    # @param domain [Hecks::DomainModel::Domain] the domain to snapshot
    # @param base_dir [String] project root directory
    # @return [String] path to the written snapshot file
    def self.tag(version, domain, base_dir: Dir.pwd)
      dir = File.join(base_dir, VERSIONS_DIR)
      FileUtils.mkdir_p(dir)

      content = DslSerializer.new(domain).serialize
      header = "# Hecks domain snapshot\n# version: #{version}\n# tagged_at: #{Date.today}\n"
      path = File.join(dir, "#{version}.rb")
      File.write(path, header + content)
      path
    end

    # List all tagged versions, newest first.
    #
    # @param base_dir [String] project root directory
    # @return [Array<Hash>] each with :version, :tagged_at, :path keys
    def self.log(base_dir: Dir.pwd)
      dir = File.join(base_dir, VERSIONS_DIR)
      return [] unless File.directory?(dir)

      Dir[File.join(dir, "*.rb")].sort.reverse.map do |path|
        meta = parse_header(path)
        { version: meta[:version], tagged_at: meta[:tagged_at], path: path }
      end
    end

    # Load a domain from a version snapshot file.
    #
    # @param version [String] version label
    # @param base_dir [String] project root directory
    # @return [Hecks::DomainModel::Domain, nil]
    def self.load_version(version, base_dir: Dir.pwd)
      path = File.join(base_dir, VERSIONS_DIR, "#{version}.rb")
      return nil unless File.exist?(path)

      Kernel.load(path)
      Hecks.last_domain
    end

    # Check if a version snapshot exists.
    #
    # @param version [String] version label
    # @param base_dir [String] project root directory
    # @return [Boolean]
    def self.exists?(version, base_dir: Dir.pwd)
      File.exist?(File.join(base_dir, VERSIONS_DIR, "#{version}.rb"))
    end

    # Return the latest tagged version label, or nil if none exist.
    #
    # @param base_dir [String] project root directory
    # @return [String, nil]
    def self.latest_version(base_dir: Dir.pwd)
      entries = log(base_dir: base_dir)
      entries.first&.fetch(:version)
    end

    # Parse metadata header from a snapshot file.
    #
    # @param path [String] file path
    # @return [Hash] with :version and :tagged_at keys
    def self.parse_header(path)
      version = nil
      tagged_at = nil
      File.foreach(path) do |line|
        break unless line.start_with?("#")
        version = $1 if line =~ /^# version:\s*(.+)/
        tagged_at = $1 if line =~ /^# tagged_at:\s*(.+)/
      end
      { version: version, tagged_at: tagged_at }
    end
  end
end
