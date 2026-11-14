require "tmpdir"
require "fileutils"

# Runs every git a spec starts with no global or system configuration and no identity, as a CI
# runner does: `GIT_CONFIG_GLOBAL` names an empty file, `GIT_CONFIG_NOSYSTEM` hides the system
# file and `user.useConfigOnly` refuses a guessed identity. A spec that commits must name its
# own identity (`-c user.name=…` or `GIT_AUTHOR_*`), so a spec that leans on the owner's global
# identity fails here as it would in CI.
module GitIdentityFree
  # The identity variables a commit reads before any configuration file.
  IDENTITY_KEYS = %w[GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL].freeze

  # The settings handed to git through `GIT_CONFIG_COUNT`.
  CONFIG = { "user.useConfigOnly" => "true" }.freeze

  # Sets the variables on an environment hash.
  #
  # @param env [Hash] the environment to change, the process's own by default
  # @param empty_config [String] path of an empty file standing in for the global configuration
  # @return [Hash] env
  def self.apply!(env = ENV, empty_config: self.empty_config)
    env["GIT_CONFIG_GLOBAL"] = empty_config
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    IDENTITY_KEYS.each { |key| env.delete(key) }
    count!(env)
  end

  # @return [String] the empty configuration file, made on first use and removed when the
  #   process that made it exits
  def self.empty_config
    @empty_config ||= begin
      dir = Dir.mktmpdir("hecks-git-identity-free")
      owner = Process.pid
      at_exit { FileUtils.rm_rf(dir) if Process.pid == owner }
      File.join(dir, "gitconfig").tap { |path| File.write(path, "") }
    end
  end

  # Writes `CONFIG` as `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n` and `GIT_CONFIG_VALUE_n`.
  #
  # @param env [Hash] the environment to change
  # @return [Hash] env
  def self.count!(env)
    env["GIT_CONFIG_COUNT"] = CONFIG.size.to_s
    CONFIG.each_with_index do |(key, value), index|
      env["GIT_CONFIG_KEY_#{index}"] = key
      env["GIT_CONFIG_VALUE_#{index}"] = value
    end
    env
  end
end

GitIdentityFree.apply!
