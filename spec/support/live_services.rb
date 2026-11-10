require "hecks/rust_build/session_build"

# The tags whose examples reach a live service (a real AWS account, say), and the one gate that
# keeps them out of every run that did not ask for them. Tags are listed in the Tickets world's
# `live_services` row, with `ALWAYS` added, so a world that cannot be read still gates them.
#
# A tag exclusion is not enough: a full-description filter (`--example`, which every launcher spec
# run passes) clears RSpec's exclusions, so an excluded example runs there. What RSpec keeps under
# every filter is an `:if` in the metadata, so each tag sets `:if` to whether the run opted in:
# the `HECKS_LIVE_SERVICES` variable names the tag (`HECKS_LIVE_SERVICES=cloudfront`). A plain run
# still needs the tag as well (`rspec --tag cloudfront`). A verification hands no such variable to
# its checks (`MainIntegration::CommandRunner::DROPPED`), so it can never opt in.
module LiveServices
  # The variable a run that means to reach a live service sets, naming the tags.
  VARIABLE = "HECKS_LIVE_SERVICES".freeze

  # The tags gated whatever the world says.
  ALWAYS = %w[cloudfront].freeze

  # The checkout the specs belong to.
  ROOT = File.expand_path("../..", __dir__)

  module_function

  # @param root [String] a hecks checkout
  # @return [Array<String>] the gated tags: `ALWAYS` and the world's
  def tags(root = ROOT)
    ALWAYS | Array(Hecks::RustBuild::SessionBuild.world_row(root, "live_services")[:tags]).map(&:to_s)
  end

  # @param tag [String] a gated tag
  # @param env [#fetch] the environment
  # @return [Boolean] whether the run opted in to that tag
  def asked_for?(tag, env = ENV) = env.fetch(VARIABLE, "").split(/[\s,]+/).include?(tag.to_s)

  # Whether the AWS CLI could have credentials, judged without a call that may wait on the
  # network: a key, a profile or a web identity in the environment, or a credentials or config
  # file under `~/.aws`.
  #
  # @param env [#fetch] the environment
  # @param home [String] the home directory
  # @return [Boolean]
  def aws_credentials?(env = ENV, home = Dir.home)
    named = %w[AWS_ACCESS_KEY_ID AWS_PROFILE AWS_WEB_IDENTITY_TOKEN_FILE].any? { |name| !env.fetch(name, "").to_s.empty? }
    named || %w[credentials config].any? { |file| File.file?(File.join(home, ".aws", file)) }
  end

  # @param config [RSpec::Core::Configuration]
  # @return [void]
  def install(config)
    tags.each do |tag|
      config.filter_run_excluding tag.to_sym => true
      config.define_derived_metadata(tag.to_sym => true) { |metadata| metadata[:if] = asked_for?(tag) }
    end
  end
end
