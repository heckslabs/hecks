# Hecks::DomainHelpers
#
# Shared helpers for CLI commands that work with domains:
# resolving domain files, loading them, finding installed gems.
# Included in CLI so all registered commands can use them.
#
module Hecks
  module DomainHelpers
    private

    def find_domain_file
      path = Dir[File.join(Dir.pwd, "*Bluebook")].first
      File.exist?(path) ? path : nil
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
            abort "No domain found. Create a Bluebook file or install a domain gem."
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
        file = Dir[File.join(path_or_name, "*Bluebook")].first
        return nil unless File.exist?(file)
        load_domain_file(file)
      elsif File.exist?(path_or_name)
        load_domain_file(path_or_name)
      else
        local = File.join(Dir.pwd, path_or_name, "Bluebook")
        File.exist?(local) ? load_domain_file(local) : nil
      end
    end

    def load_domain_file(file)
      Kernel.load(file)
      domain = Hecks.last_domain
      domain.source_path = file
      domain
    end

    def find_installed_domains
      ::Gem::Specification.select { |spec| Dir[File.join(spec.full_gem_path, "*Bluebook")].any? }
        .group_by(&:name).map { |name, specs| [name, specs.map(&:version).sort.reverse] }
    end

    def print_mother_earth_report(validator)
      report = validator.mother_earth_report
      return unless report

      say ""
      say "Mother Earth Report", :bold
      say "  Goals declared: #{report[:goals_declared].map(&:to_s).join(', ')}"
      report[:goals_declared].each do |goal|
        if report[:passing_goals].include?(goal)
          say "  [PASS] #{goal}", :green
        else
          say "  [FAIL] #{goal}", :red
        end
      end
      return if report[:violations].empty?

      say ""
      say "  Violations:", :red
      report[:violations].each { |v| say "    - #{v}", :red }
    end

    def domain_template(name)
      <<~RUBY
        Hecks.domain "#{name}" do
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
