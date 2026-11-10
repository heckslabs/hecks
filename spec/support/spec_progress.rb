# Where a spec run is, for a bound that ends it: when `HECKS_SPEC_PROGRESS` names a file, every
# example writes its file and full description there before it runs, so
# `Hecks::Adapters::BoundedCapture` can name the example a stopped run was in.
module SpecProgress
  # The variable naming the progress file; `BoundedCapture::PROGRESS` names the same.
  VARIABLE = "HECKS_SPEC_PROGRESS".freeze

  module_function

  # @param config [RSpec::Core::Configuration]
  # @param env [#fetch] the environment
  # @return [void]
  def install(config, env = ENV)
    path = env.fetch(VARIABLE, "").to_s
    return if path.empty?

    config.before { |example| File.write(path, "#{example.metadata[:rerun_file_path]}\t#{example.full_description}") }
  end
end
