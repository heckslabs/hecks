# Hecks::GovernanceGuard
#
# Entry-point agnostic governance checker that validates domain operations
# against world concerns. Works from CLI, HTTP, REPL, MCP, or workshop --
# accepts a domain object directly, no framework coupling.
#
# Uses rule-based checks for each declared world concern (transparency,
# consent, privacy, security). When an LLM API key is available, enriches
# results with AI-powered analysis. Falls back gracefully to rule-based
# checks when no API key is present.
#
#   domain = Hecks.domain("Health") { world_concerns :privacy, :consent; ... }
#   result = Hecks::GovernanceGuard.new(domain).check
#   result.passed?      # => false
#   result.violations   # => [{ concern: :privacy, message: "..." }]
#   result.suggestions  # => ["Add visible: false to PII attributes"]
#
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::AI::GovernanceParagraph,
  base_dir: File.expand_path("governance_guard", __dir__)
)

module Hecks
  class GovernanceGuard
    SUPPORTED_CONCERNS = %i[transparency consent privacy security].freeze

    # @param domain [Hecks::BluebookModel::Structure::Domain] the domain to check
    # @param api_key [String, nil] Anthropic API key for AI-enriched analysis
    def initialize(domain, api_key: nil)
      @domain = domain
      @api_key = api_key || ENV["ANTHROPIC_API_KEY"]
    end

    # Run governance checks against all declared world concerns.
    # Returns a Result with violations and suggestions.
    #
    # @return [Hecks::GovernanceGuard::Result]
    def check
      concerns = @domain.world_concerns & SUPPORTED_CONCERNS
      return Result.new if concerns.empty?

      all_violations = []
      all_suggestions = []

      concerns.each do |concern|
        violations, suggestions = run_concern_check(concern)
        all_violations.concat(violations)
        all_suggestions.concat(suggestions)
      end

      if @api_key && all_violations.any?
        ai_suggestions = fetch_ai_suggestions(all_violations)
        all_suggestions.concat(ai_suggestions)
      end

      Result.new(violations: all_violations, suggestions: all_suggestions.uniq)
    end

    private

    def run_concern_check(concern)
      case concern
      when :transparency then ConcernChecks.check_transparency(@domain)
      when :consent      then ConcernChecks.check_consent(@domain)
      when :privacy      then ConcernChecks.check_privacy(@domain)
      when :security     then ConcernChecks.check_security(@domain)
      else [[], []]
      end
    end

    def fetch_ai_suggestions(violations)
      summary = violations.map { |v| "#{v[:concern]}: #{v[:message]}" }.join("\n")
      prompt = "Given these domain governance violations in a Hecks domain model, " \
               "provide 1-3 brief, actionable suggestions:\n\n#{summary}"

      client = Hecks::AI::LlmClient.new(api_key: @api_key)
      response = client.generate_domain(prompt)
      Array(response[:suggestions] || [])
    rescue => _e
      [] # AI enrichment is best-effort
    end
  end
end
