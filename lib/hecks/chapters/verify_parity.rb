# Hecks::Chapters::ParityVerifier
#
# Checks that the Rust projection reads every Bluebook identically
# to the Ruby runtime. Compares aggregate, command, policy, and
# fixture counts. A mismatch is a compilation error — the Rust
# binary must be a faithful projection of the Ruby IR.
#
#   Hecks::Chapters::ParityVerifier.run
#   Hecks::Chapters::ParityVerifier.run(format: :documentation)
#
module Hecks
  module Chapters
    module ParityVerifier
      Result = Struct.new(:pass_count, :errors)

      HECKS_LIFE = File.expand_path("../../../hecks_life/target/debug/hecks-life", __dir__)

      def self.run(format: :progress)
        result = Result.new(0, [])

        unless File.exist?(HECKS_LIFE)
          result.errors << { context: "Parity", message: "hecks-life binary not found at #{HECKS_LIFE}" }
          return result
        end

        puts "\e[1mParity (Ruby ↔ Rust)\e[0m" if format == :documentation

        chapters = Hecks::Chapters.constants
          .map { |c| Hecks::Chapters.const_get(c) }
          .select { |m| m.respond_to?(:definition) }

        chapters.each do |mod|
          domain = mod.definition
          next if domain.aggregates.empty?

          path = domain.source_path
          next unless path && File.exist?(path)

          check(result, format, domain.name) do
            rust_out = `#{HECKS_LIFE} counts "#{path}" 2>&1`.strip
            raise "Rust parse failed: #{rust_out}" if rust_out.empty? || rust_out.include?("Cannot read")

            rust = rust_out.split("|")
            raise "Rust output malformed: #{rust_out}" if rust.size < 5

            ruby_aggs = domain.aggregates.size
            ruby_cmds = domain.all_commands.size
            ruby_pols = domain.policies.size
            ruby_fixs = domain.respond_to?(:fixtures) ? domain.fixtures.size : 0

            diffs = []
            diffs << "aggregates: rust=#{rust[1]} ruby=#{ruby_aggs}" if rust[1].to_i != ruby_aggs
            diffs << "commands: rust=#{rust[2]} ruby=#{ruby_cmds}" if rust[2].to_i != ruby_cmds
            diffs << "policies: rust=#{rust[3]} ruby=#{ruby_pols}" if rust[3].to_i != ruby_pols
            diffs << "fixtures: rust=#{rust[4]} ruby=#{ruby_fixs}" if rust[4].to_i != ruby_fixs

            raise diffs.join("; ") if diffs.any?
          end
        end

        puts "" if format == :documentation
        result
      end

      def self.check(result, format, name)
        yield
        result.pass_count += 1
        if format == :documentation
          puts "  \e[32m✓\e[0m #{name}"
        else
          print "."
        end
      rescue => e
        result.errors << { context: "Parity/#{name}", message: e.message }
        if format == :documentation
          puts "  \e[31m✗\e[0m #{name} — #{e.message}"
        else
          print "\e[31mF\e[0m"
        end
      end
    end
  end
end
