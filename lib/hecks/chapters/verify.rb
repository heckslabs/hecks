# Hecks::Chapters.verify
#
# The Bluebook is the spec. This method loads every chapter,
# validates its IR, and reports any issues. No RSpec needed —
# the chapter definitions are the test suite.
#
#   Hecks::Chapters.verify                        # => dots (progress)
#   Hecks::Chapters.verify(format: :documentation) # => verbose tree
#
# Run from CLI:
#   bin/verify                        # progress (dots)
#   bin/verify --format documentation # verbose tree
#   bin/verify -v                     # shortcut for documentation
#
module Hecks
  module Chapters
    class VerificationError < StandardError; end

    FORMATS = %i[progress documentation].freeze

    def self.verify(format: :progress, verbose: false)
      format = :documentation if verbose
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      errors = []
      pass_count = 0

      chapter_modules = constants
        .map { |c| const_get(c) }
        .select { |m| m.respond_to?(:definition) }

      if format == :progress
        seed = Random.new_seed
        chapter_modules = chapter_modules.shuffle(random: Random.new(seed))
      end

      chapter_modules.each do |mod|
        domain = mod.definition

        if domain.aggregates.empty?
          errors << { context: domain.name, message: "no aggregates" }
          format == :documentation ? puts("\e[31m  #{domain.name} — EMPTY (no aggregates)\e[0m") : print("\e[31mF\e[0m")
          next
        end

        if format == :documentation
          cmd_count = domain.aggregates.sum { |a| a.commands.size }
          puts "\e[1m#{domain.name}\e[0m (#{domain.aggregates.size} aggregates, #{cmd_count} commands)"
        end

        aggs = format == :progress ? domain.aggregates.shuffle(random: Random.new(seed)) : domain.aggregates
        aggs.each do |agg|
          if agg.description
            pass_count += 1
            if format == :documentation
              cmds = agg.commands.map(&:name).join(", ")
              puts "  \e[32m✓\e[0m #{agg.name} — #{agg.description}"
              puts "    commands: #{cmds}" unless agg.commands.empty?
            else
              print "."
            end
          else
            errors << { context: "#{domain.name}/#{agg.name}", message: "missing description" }
            format == :documentation ? puts("  \e[31m✗\e[0m #{agg.name} — missing description") : print("\e[31mF\e[0m")
          end
        end

        puts "" if format == :documentation
      end

      # Phase 2: Contract verification
      puts "" if format == :progress
      puts "\e[1mContracts\e[0m" if format == :documentation
      require "hecks/chapters/verify_contracts"
      contract_result = ContractVerifier.run(format: format)
      pass_count += contract_result.pass_count
      errors.concat(contract_result.errors)

      # Phase 3: Runtime verification (boot + execute + round-trip)
      puts "" if format == :progress
      require "hecks/chapters/verify_runtime"
      runtime_result = RuntimeVerifier.run(format: format)
      pass_count += runtime_result.pass_count
      errors.concat(runtime_result.errors)

      # Phase 4: Generator verification (runtime wiring generators)
      puts "" if format == :progress
      require "hecks/chapters/verify_generators"
      generator_result = GeneratorVerifier.run(format: format)
      pass_count += generator_result.pass_count
      errors.concat(generator_result.errors)

      # Phase 5: File coverage (every lib file must match an aggregate)
      warnings = []
      puts "" if format == :progress
      require "hecks/chapters/verify_coverage"
      coverage_result = CoverageVerifier.run(format: format)
      pass_count += coverage_result.pass_count
      warnings.concat(coverage_result.errors)

      # Phase 6: Parity (Ruby ↔ Rust projection)
      puts "" if format == :progress
      require "hecks/chapters/verify_parity"
      parity_result = ParityVerifier.run(format: format)
      pass_count += parity_result.pass_count
      errors.concat(parity_result.errors)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      total = pass_count + errors.size + warnings.size
      puts "" if format == :progress

      if errors.any?
        puts "Failures:"
        puts ""
        errors.each_with_index do |err, i|
          puts "  #{i + 1}) #{err[:context]}"
          puts "     #{err[:message]}"
          puts ""
        end
      end

      if warnings.any?
        puts "\e[33mWarnings (#{warnings.size}):\e[0m"
        warnings.first(10).each do |w|
          puts "  \e[33m- #{w[:context]}: #{w[:message]}\e[0m"
        end
        puts "  \e[33m... and #{warnings.size - 10} more\e[0m" if warnings.size > 10
        puts ""
      end

      color = errors.any? ? "\e[31m" : "\e[32m"
      puts "#{color}Verified in #{format('%.2f', elapsed)}s\e[0m"

      if errors.any?
        raise VerificationError,
          "Bluebook verification failed:\n  " +
          errors.map { |e| "#{e[:context]}: #{e[:message]}" }.join("\n  ")
      end

      if elapsed > 0.5
        raise VerificationError,
          "Bluebook verification too slow: #{format('%.2f', elapsed)}s (max 0.5s)"
      end

      true
    end
  end
end
