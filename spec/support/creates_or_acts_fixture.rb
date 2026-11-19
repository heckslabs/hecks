# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Boots spec/fixtures/creates_or_acts.bluebook from a scratch copy, for the creates_or_acts specs.
module CreatesOrActsFixture
  PATH = File.join(InMemoryDomain::ROOT, "spec/fixtures/creates_or_acts.bluebook")

  # Boots the fixture from a scratch copy for the length of `example`.
  def with_fixture_runtime(example)
    Dir.mktmpdir("creates-or-acts") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bluebook"))
      FileUtils.cp(PATH, File.join(dir, "bluebook"))
      @runtime = Hecks.boot(File.join(dir, "bluebook"), install_driving: false)
      example.run
    end
  end

  def page = @runtime.registry.bluebooks.fetch("CreatesOrActs").aggregates.first
  def command(name) = page.commands.find { |verb| verb.hecks_name == name }

  # The texts of the lines a Write left on the page it acted on.
  def write(title, text)
    result = @runtime.dispatch_flat("CreatesOrActs::Page.Write", title: { value: title }, text: text)
    Array(result.instance[:lines]).map { |line| line.to_h[:text] }
  end
end
