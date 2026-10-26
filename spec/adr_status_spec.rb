require "spec_helper"

# A decision record's status line says where its decision stands, and often names the files that
# carry it out. A status that names a path missing from the tree claims something the tree cannot
# back, so it either names paths that exist or says it is historical: `Superseded`, `Historical`,
# `Retired`, `Withdrawn` or `Rejected`, with the reason, in the record's opening lines.
module AdrStatus
  ROOT = File.expand_path("..", __dir__)
  HISTORICAL = /\b(?:Superseded|Historical|Retired|Withdrawn|Rejected)\b/i
  OPENING = 12

  module_function

  def records
    Dir.glob(File.join(ROOT, "docs/{,implemented/}decisions/[0-9][0-9][0-9][0-9]-*.md"))
  end

  def opening(path)
    File.foreach(path).first(OPENING)
  end

  def status_line(path)
    opening(path).find { |line| line.match?(/\A(?:>\s*)?\*\*Status\b|\AStatus:/) }
  end

  def named_paths(line)
    line.scan(/`([^`\n]+)`/).flatten.filter_map do |code|
      token = code.strip.split(/\s+/).first.to_s.sub(/:\d+(?:-\d+)?\z/, "").chomp("/")
      token if token.match?(%r{\A(?:lib|spec|rust|examples|exe|docs)/[\w./-]+\z}) && !token.include?("..")
    end
  end

  # A record cites another by number alone (`docs/decisions/0041`), so a prefix names a file too.
  def exists?(named)
    return true if File.exist?(File.join(ROOT, named))

    number = named[%r{\Adocs/(?:implemented/)?decisions/(\d{4})\z}, 1]
    number && records.any? { |record| File.basename(record).start_with?("#{number}-") }
  end

  def without_status
    records.reject { |path| status_line(path) }.map { |path| path.delete_prefix("#{ROOT}/") }.sort
  end

  def gone_paths
    records.sort.flat_map do |path|
      line = status_line(path)
      next [] if line.nil? || opening(path).join.match?(HISTORICAL)

      named_paths(line).reject { |named| exists?(named) }.map { |named| "#{path.delete_prefix("#{ROOT}/")}: #{named}" }
    end
  end
end

RSpec.describe "architecture decision record statuses" do
  it "has a status line in every record" do
    missing = AdrStatus.without_status

    expect(missing).to be_empty, "decision records with no status line:\n#{missing.join("\n")}"
  end

  it "names only paths that exist, unless the record is marked historical" do
    gone = AdrStatus.gone_paths

    expect(gone).to be_empty, "statuses naming gone paths; fix the path or mark the record Historical:\n#{gone.join("\n")}"
  end
end
