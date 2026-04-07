# Hecks::DomainHelpers
#
# Shared helpers for CLI commands that work with domains:
# resolving domain files, loading them, finding installed gems.
# Included in CLI so all registered commands can use them.
#
module Hecks
  # Hecks::DomainHelpers
  #
  # Shared CLI helpers for resolving domain files, loading domains, and finding installed gems.
  #
  module DomainHelpers
    private

    def find_domain_file
      %w[*.hec Bluebook *Bluebook].each do |pattern|
        files = Dir[File.join(Dir.pwd, pattern)].reject { |f| File.basename(f).match?(/hecksagon/i) }
        return files.first if files.any?
      end
      nil
    end

    def resolve_domain_option
      if options[:domain]
        resolve_domain(options[:domain])
      else
        file = find_domain_file
        if file
          load_domain_file(file)
        else
          installed = find_installed_domains
          case installed.size
          when 0
            abort "No domain found. Create a .hec file or install a domain gem."
          when 1
            name, _ = installed.first
            say "Auto-selected domain: #{name}", :green
            resolve_domain(name)
          else
            say "Multiple domains found:", :yellow
            installed.each_with_index do |(name, versions), i|
              say "  #{i + 1}. #{name} (#{versions.map { |v| "v#{v}" }.join(", ")})"
            end
            choice = ask("Select domain [1-#{installed.size}]:").to_i
            abort "Invalid selection" unless choice.between?(1, installed.size)
            name, _ = installed[choice - 1]
            resolve_domain(name)
          end
        end
      end
    end

    def resolve_domain(path_or_name)
      if path_or_name.nil?
        file = find_domain_file
        return nil unless file
        load_domain_file(file)
      elsif File.directory?(path_or_name)
        file = find_domain_in(path_or_name)
        return nil unless file
        load_domain_file(file)
      elsif File.exist?(path_or_name)
        load_domain_file(path_or_name)
      else
        local_dir = File.join(Dir.pwd, path_or_name)
        file = File.directory?(local_dir) ? find_domain_in(local_dir) : nil
        file ? load_domain_file(file) : nil
      end
    end

    def load_domain_file(file)
      Kernel.load(file)
      domain = Hecks.last_domain
      domain.source_path = file
      domain
    end

    def find_domain_in(dir)
      %w[*.hec Bluebook *Bluebook].each do |pattern|
        files = Dir[File.join(dir, pattern)].reject { |f| File.basename(f).match?(/hecksagon/i) }
        return files.first if files.any?
      end
      nil
    end

    def find_installed_domains
      ::Gem::Specification.select { |spec|
        Dir[File.join(spec.full_gem_path, "*.hec")].any? || Dir[File.join(spec.full_gem_path, "*Bluebook")].any?
      }.group_by(&:name).map { |name, specs| [name, specs.map(&:version).sort.reverse] }
    end

    def print_world_concerns_report(validator)
      report = validator.world_concerns_report
      return unless report

      say ""
      say "World Concerns Report", :bold
      say "  Concerns declared: #{report[:concerns_declared].map(&:to_s).join(', ')}"
      report[:concerns_declared].each do |concern|
        if report[:passing_concerns].include?(concern)
          say "  [PASS] #{concern}", :green
        else
          say "  [FAIL] #{concern}", :red
        end
      end
      return if report[:violations].empty?

      say ""
      say "  Violations:", :red
      report[:violations].each { |v| say "    - #{v}", :red }
    end

    def print_governance_report(domain)
      require "hecks_ai"
      guard = Hecks::GovernanceGuard.new(domain)
      result = guard.check

      say ""
      say "Governance Check", :bold
      if result.passed?
        say "  All governance checks passed", :green
      else
        say "  Violations:", :red
        result.violations.each do |v|
          say "    [#{v[:concern]}] #{v[:message]}", :red
        end
      end

      return if result.suggestions.empty?

      say ""
      say "  Suggestions:", :cyan
      result.suggestions.each { |s| say "    - #{s}", :cyan }
    end

    def domain_template(name, world_concerns: [], extensions: [], stub: false)
      header_lines = []

      if stub
        header_lines << "  # world_concerns :privacy, :consent  # add when ready"
      elsif world_concerns.any?
        header_lines << "  world_concerns #{world_concerns.map { |g| ":#{g}" }.join(", ")}"
        extensions.each { |ext| header_lines << "  extend :#{ext}" }
      end

      header = header_lines.any? ? "\n#{header_lines.join("\n")}\n" : ""

      <<~RUBY
        Hecks.domain "#{name}" do#{header}
          aggregate "Example" do
            attribute :name, String
            validation :name, presence: true
            command "CreateExample" do
              attribute :name, String
            end
          end
        end
      RUBY
    end
  end
end
