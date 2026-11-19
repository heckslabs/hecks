# frozen_string_literal: true

# The launcher's help with everything a bluebook says taken out: the names, headings and layout
# stay, and each description, aggregate note and module vision is masked. A reworded description
# leaves the masked help byte-identical, so the help snapshot pins the surface and never the
# bluebook's prose, which `spec/cli_help_descriptions_spec.rb` checks against the bluebooks.
#
# Only the sections projected from bluebooks are masked (`everyday:`, `commands:`, `queries:` and
# `bluebooks:`, each running to its blank line); the usage lines and the footer are the launcher's
# own text and stay pinned. A row keeps its indent and name and drops its padding, so a longer
# name added to a group does not re-pad every row beside it.
module CliHelpMask
  # The heading that opens a masked section, at the left margin.
  SECTION = /\A(everyday|commands|queries|bluebooks)\b.*:\z/

  # An aggregate's heading inside a section: its name and a colon, indented two spaces.
  HEADING = /\A  [A-Z]\w*:\z/

  # A row: its indent, its name, then two spaces or more before its description, or nothing.
  ROW = /\A(?<indent>\s+)(?<name>\S+)(?:\s{2,}(?<text>.*))?\z/

  # The masked mark that stands for an aggregate's note.
  NOTE = "…"

  # A description's alias note, `(also: console!)`, which the row carries after its text.
  ALIAS = /\s\(also: [^)]+\)\z/

  module_function

  # The help with its bluebook prose masked.
  #
  # @param text [String] the launcher's output
  # @return [String] the same lines, each description, note and vision masked
  def mask(text)
    section = nil
    previous = nil
    lines = text.lines(chomp: true).each_with_index.map do |line, index|
      section = section_after(section, line)
      masked = mask_line(line, index, section, previous)
      previous = line
      masked
    end
    "#{lines.join("\n")}\n"
  end

  # The section a line sits in: a section heading opens one, a blank line closes it.
  def section_after(section, line)
    return Regexp.last_match(1) if line.match(SECTION)
    return nil if line.empty?

    section
  end

  # One line masked by where it sits: the module's opening line, a note, or a row.
  def mask_line(line, index, section, previous)
    return vision_masked(line) if index.zero?
    return line if section.nil? || line.match?(SECTION) || line.match?(HEADING)
    return note_masked(line) if note?(line, previous)

    row_masked(line)
  end

  # The module's opening line, `build — Compile and regenerate.`, as `build —`.
  def vision_masked(line)
    line.sub(/ — .*\z/, " —")
  end

  # Whether a line is an aggregate's note: the first line after its heading that is not a row
  # with a description. An aggregate with no note opens straight onto its rows.
  def note?(line, previous)
    return false unless previous&.match?(HEADING)

    match = line.match(ROW)
    match.nil? || match[:text].nil?
  end

  # A note masked to its indent and the note mark.
  def note_masked(line)
    "#{line[/\A\s*/]}#{NOTE}"
  end

  # A row masked to its indent and name; a line that is not a row is left as it is.
  def row_masked(line)
    match = line.match(ROW)
    match ? "#{match[:indent]}#{match[:name]}" : line
  end

  # The rows of the masked sections, with what each says.
  #
  # @param text [String] the launcher's output
  # @return [Array<Hash{Symbol => String}>] each row's `:section`, `:group` (its aggregate heading,
  #   or nil), `:name` and `:text` (its description, alias note left out)
  def rows(text)
    walk = { section: nil, group: nil, previous: nil }
    text.lines(chomp: true).filter_map { |line| row_entry(walk, line) }
  end

  # One row's entry, or nil for a line that is no row; `walk` carries the section and heading.
  def row_entry(walk, line)
    walk[:group] = nil if line.match?(SECTION) || line.empty?
    walk[:section] = section_after(walk[:section], line)
    previous = walk[:previous]
    walk[:previous] = line
    walk[:group] = line.strip.chomp(":") if walk[:section] && line.match?(HEADING)
    described_row(walk, line, previous)
  end

  # The entry of a row with a description, or nil for a note, a heading or a bare name.
  def described_row(walk, line, previous)
    return nil if walk[:section].nil? || line.match?(SECTION) || line.match?(HEADING) || note?(line, previous)

    match = line.match(ROW)
    return nil unless match && match[:text]

    { section: walk[:section], group: walk[:group], name: match[:name], text: match[:text].sub(ALIAS, "") }
  end

  # The aggregate notes of the masked sections.
  #
  # @param text [String] the launcher's output
  # @return [Array<Hash{Symbol => String}>] each note's `:group` (its aggregate) and `:text`
  def notes(text)
    text.lines(chomp: true).each_cons(2).filter_map do |heading, line|
      { group: heading.strip.chomp(":"), text: line.strip } if heading.match?(HEADING) && note?(line, heading)
    end
  end

  # The first line two texts differ on, said as the line and both versions of it.
  #
  # @param expected [String] the golden
  # @param actual [String] the masked help
  # @return [String, nil] the difference, or nil when the texts are the same
  def first_difference(expected, actual)
    e = expected.lines
    a = actual.lines
    line = (0...[e.size, a.size].max).find { |i| e[i] != a[i] }
    return nil unless line

    "line #{line + 1}: expected #{e[line].inspect}, got #{a[line].inspect}"
  end
end
