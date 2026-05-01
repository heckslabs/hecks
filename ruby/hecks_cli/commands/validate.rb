# Hecks::CLI -- validate command
#
# The single source of truth for project health. Discovers projects,
# boots them, validates domains, checks UL tag coverage, reports
# capability status. Same output at CLI, server boot, and CI.
#
#   hecks validate                    # validate current directory
#   hecks validate --format json      # machine-readable output
#
Hecks::CLI.handle(:validate) do |inv|
  require "hecks/validate"
  result = Hecks::Validate.run(Dir.pwd, format: options[:format] || "text")
  exit(result[:errors].any? ? 1 : 0)
end
