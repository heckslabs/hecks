# GoHecks::LifecycleGenerator
#
# Generates Go lifecycle support: status type, state constants,
# predicate methods, and transition validation.
#
#   LifecycleGenerator.new(lifecycle, aggregate_name: "Order", package: "domain").generate
#
module GoHecks
  class LifecycleGenerator
    include GoUtils

    def initialize(lifecycle, aggregate_name:, package:)
      @lc = lifecycle
      @agg = aggregate_name
      @package = package
    end

    def generate
      @field = GoUtils.pascal_case(@lc.field)
      b = GoCodeBuilder.new(@package)

      b.const_block do |c|
        @lc.states.each do |state|
          c.value("#{@agg}Status#{GoUtils.pascal_case(state)}", "\"#{state}\"")
        end
      end

      predicate_methods(b)
      b.blank
      transition_method(b)

      b.to_s
    end

    private

    def predicate_methods(b)
      @lc.states.each do |state|
        const = "#{@agg}Status#{GoUtils.pascal_case(state)}"
        b.one_liner(@agg, "Is#{GoUtils.pascal_case(state)}", "bool", "return a.#{@field} == #{const}")
      end
    end

    def transition_method(b)
      b.receiver(@agg, "ValidTransition(target string)", "bool") do |m|
        m.line("switch {")
        @lc.transitions.each do |cmd_name, _|
          target = @lc.target_for(cmd_name)
          from = @lc.from_for(cmd_name)
          next unless target
          if from
            from_list = from.is_a?(Array) ? from : [from]
            from_check = from_list.map { |f| "a.#{@field} == \"#{f}\"" }.join(" || ")
            m.line("case target == \"#{target}\" && (#{from_check}): return true")
          else
            m.line("case target == \"#{target}\": return true")
          end
        end
        m.line("default: return false")
        m.line("}")
      end
    end
  end
end
