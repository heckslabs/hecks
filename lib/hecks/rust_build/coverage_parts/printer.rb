# frozen_string_literal: true

module Hecks
  module RustBuild
    module Coverage
      # Prints a coverage report: the implemented, deferred and gap buckets of a module's findings.
      module Printer
        module_function

        # @param domain [String] the generated module's name
        # @param name [String] the domain's name from its `ir.json`
        # @param findings [Array<Hash>] the manifest entries plus synthetic `unaccounted` ones
        # @param allowlist [#call] answers the allowlist rule excusing a finding, or nil
        # @return [Integer] 0 when no gap remains, 1 otherwise
        def report(domain, name, findings, allowlist)
          implemented, deferred, gap = buckets(findings, allowlist)
          banner(domain)
          puts summary(name, findings.size, [implemented, deferred, gap])
          print_bucket("IMPLEMENTED", implemented) unless implemented.empty?
          print_deferred(deferred, allowlist)
          print_gaps(gap)
          puts
          gap.empty? ? 0 : 1
        end

        # A construct is implemented only when generated and routed (where routing applies): a
        # `dispatch_*` that compiles but nothing can call is not working.
        def buckets(findings, allowlist)
          implemented, remainder = findings.partition { |f| f[:generated] && f[:routed] != false }
          deferred, gap = remainder.partition { |f| allowlist.call(f) }
          [implemented, deferred, gap]
        end

        def summary(name, total, buckets)
          implemented, deferred, gap = buckets.map(&:size)
          "#{name} — #{total} constructs accounted for " \
            "(#{implemented} implemented, #{deferred} deferred, #{gap} GAP)"
        end

        def banner(domain)
          puts "=" * 72
          puts "hecks rust_coverage #{domain}  (source: manifest.json)"
          puts "=" * 72
        end

        def print_bucket(label, entries)
          puts "\n#{label} (#{entries.size})"
          sorted(entries).each { |entry| print_entry(entry) }
        end

        def print_deferred(deferred, allowlist)
          puts "\nDEFERRED (#{deferred.size}) — on the allowlist, with its cited reason"
          sorted(deferred).each do |entry|
            puts "  [#{entry[:kind]}] #{entry[:id]}"
            puts "      allowlist: #{allowlist.call(entry)[:doc]}"
          end
        end

        def print_gaps(gap)
          puts "\nGAP (#{gap.size}) — missing, and NOT on the allowlist: a real, actionable finding"
          sorted(gap).each { |entry| print_entry(entry) }
        end

        def print_entry(entry)
          line = "  [#{entry[:kind]}] #{entry[:id]}"
          line += " (#{entry[:gap_class]})" if entry[:gap_class]
          puts line
          puts "      #{entry[:reason]}" if entry[:reason]
        end

        def sorted(entries) = entries.sort_by { |entry| [entry[:kind].to_s, entry[:id]] }
      end
    end
  end
end
