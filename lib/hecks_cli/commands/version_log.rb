Hecks::Chapters.load_aggregates(
  Hecks::Cli::CliInternals,
  base_dir: __dir__
)

Hecks::CLI.handle(:version_log) do |inv|
  entries = Hecks::DomainVersioning.log(base_dir: Dir.pwd)

  if entries.empty?
    say "No versions tagged yet. Run `hecks version_tag <version>` to tag one.", :yellow
    next
  end

  lines = Hecks::CLI::VersionLogFormatter.format(entries)
  lines.each { |line| say line }
end
