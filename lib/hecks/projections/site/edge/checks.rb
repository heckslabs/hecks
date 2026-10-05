# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Edge
        # What the edge rows must satisfy before anything is built from them: each reference is to a
        # thing that exists, no two rows claim one name or priority, and every route the edge serves
        # has the origin, the policy and, for a server behind the load balancer, the rule it needs.
        class Checks
          LOGICAL_ID = /\A[A-Za-z][A-Za-z0-9]*\z/
          INTRINSIC = /\A!(Ref|ImportValue|Sub|GetAtt)\s+\S/
          PRIORITIES = (1..50_000)

          # The id a policy reference names, or nil when it names none.
          #
          # @param reference [String] a managed policy name, an id, or an intrinsic
          # @return [Array<String>, nil] `[id_or_intrinsic, comment_or_nil]`
          def self.resolve(reference)
            managed = Deploy::Fargate::Cdn::MANAGED_POLICIES[reference]
            return managed if managed
            return [reference, nil] if Deploy::Fargate::Cdn::UUID.match?(reference) || INTRINSIC.match?(reference)

            nil
          end

          # @param edge [Edge] the edge being read, its rows set
          # @param rows [Array<Table::Row>] the route table's rows
          # @param vocabulary [Hash{Symbol => Array<String>}] the Site chapter's closed sets
          # @param problems [Array<String>] collects each problem found, one line each
          # @param template_named [Boolean] whether the caller names the template itself
          def initialize(edge, rows, vocabulary, problems, template_named: false)
            @template_named = template_named
            @edge = edge
            @rows = rows
            @vocabulary = vocabulary
            @problems = problems
          end

          # @return [void]
          def call
            check_setting
            check_policies
            check_upstreams
            check_rules
            check_routes
          end

          private

          def check_setting
            setting = @edge.setting
            return problem("Edge", "has no row; declare one member with template:") unless setting

            check_template(setting.template) if setting.template || !@template_named

            problem("Edge", "has secret_header but no secret_value") if setting.secret_header && !setting.secret_value
            problem("Edge", "has secret_value but no secret_header") if setting.secret_value && !setting.secret_header
          end

          def check_template(template)
            template = template.to_s
            problem("Edge", "has no template; declare template: or name the file to the tool") if template.empty?
            problem("Edge", "template #{template.inspect} must be a path inside the project") if
              template.start_with?("/") || template.split("/").include?("..")
          end

          def check_policies
            @edge.policies.each do |policy|
              label = "EdgePolicy #{policy.cache_class}#{" on #{policy.origin}" if policy.origin}"
              member_of(label, "cache_class", policy.cache_class, :cache)
              member_of(label, "origin", policy.origin, :origin) if policy.origin
              { cache: policy.cache, origin_request: policy.origin_request,
                response_headers: policy.response_headers }.compact.each do |field, reference|
                next if (reference == "none" && field != :cache) || self.class.resolve(reference)

                managed = Deploy::Fargate::Cdn::MANAGED_POLICIES.keys.join(", ")
                problem(label, "has #{field} #{reference.inspect}; use a managed name (#{managed}), " \
                               "a policy id or an intrinsic like !Ref Name")
              end
            end
            repeated(@edge.policies.map { |policy| [policy.cache_class, policy.origin] }, "EdgePolicy") do |key|
              "#{key[0]}#{" on #{key[1]}" if key[1]}"
            end
          end

          def check_upstreams
            @edge.upstreams.each do |upstream|
              member_of("EdgeOrigin #{upstream.origin}", "origin", upstream.origin, :origin)
              problem("EdgeOrigin #{upstream.origin}", "has id #{upstream.id.inspect}; an origin id is a logical id") unless
                LOGICAL_ID.match?(upstream.id.to_s)
            end
            repeated(@edge.upstreams.map(&:origin), "EdgeOrigin", &:itself)
          end

          def check_rules
            return check_no_alb unless @edge.alb?

            problem("EdgeRule", "rows need an Edge row with listener:") if @edge.rules.any? && !@edge.setting&.listener
            @edge.rules.each { |rule| check_rule(rule) }
            repeated(@edge.rules.map(&:rule), "EdgeRule", &:itself)
            repeated(@edge.rules.map(&:priority), "EdgeRule priority", &:to_s)
          end

          # With `alb: false` nothing routes by listener rule, so a rule row, or a route that names
          # one, describes a load balancer the project says it does not have. Every route that is
          # served by a server behind the edge still needs the origin that reaches it.
          def check_no_alb
            problem("EdgeRule", "rows describe a load balancer, and the Edge row says alb: false") if @edge.rules.any?
            @rows.select(&:alb_rule).each do |row|
              problem(row.path, "names alb_rule #{row.alb_rule}, and the Edge row says alb: false")
            end
            @rows.each do |row|
              next if row.cdn || !%w[cms domain].include?(row.origin) || @edge.upstream(row.origin)

              problem(row.path, "is served from #{row.origin}, which no EdgeOrigin maps, and with alb: false " \
                                "nothing else reaches it")
            end
          end

          def check_rule(rule)
            label = "EdgeRule #{rule.rule}"
            member_of(label, "origin", rule.origin, :origin)
            problem(label, "has origin assets; the load balancer does not front the assets origin") if rule.origin == "assets"
            problem(label, "is not a logical id") unless LOGICAL_ID.match?(rule.rule.to_s)
            unless PRIORITIES.cover?(rule.priority.to_i)
              problem(label, "has priority #{rule.priority}; a priority is #{PRIORITIES.first} to #{PRIORITIES.last}")
            end
            return if rule.origin.nil? || @edge.upstream(rule.origin)&.target_group

            problem(label, "forwards to #{rule.origin}, whose EdgeOrigin names no target_group")
          end

          def check_routes
            edge_rows = @rows.select { |row| row.cdn || row.alb_rule }
            edge_rows.each do |row|
              next if row.origin == "assets" && !row.cdn

              problem(row.path, "has origin #{row.origin}, which no EdgeOrigin maps") unless @edge.upstream(row.origin)
              next unless row.cdn && !@edge.policy(row.cache, row.origin)

              problem(row.path, "has cache class #{row.cache} on #{row.origin}, which no EdgePolicy maps")
            end
            default_rows = @rows.select { |row| row.path == "/*" && row.cdn }
            problem("the route table", "needs one row for /* : the default behaviour") if default_rows.empty?
          end

          def member_of(label, field, value, vocabulary)
            return if @vocabulary.fetch(vocabulary).include?(value)

            problem(label, "has #{field} #{value.inspect}; #{field} is one of #{@vocabulary.fetch(vocabulary).join(', ')}")
          end

          def repeated(keys, what)
            keys.tally.each { |key, count| problem(what, "#{yield(key)} is declared #{count} times") if count > 1 }
          end

          def problem(label, text) = @problems << "#{label} #{text}"
        end
      end
    end
  end
end
