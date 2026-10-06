require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"

# Pins the `^[A-Za-z_][A-Za-z0-9_]*$` allowlist guard on `make rename-schema OLD=.. NEW=..`.
# Reads a generated fixture Makefile, since the recipe generator writes files rather than
# returning them.
RSpec.describe "hecks deploy project's rename-schema OLD/NEW allowlist, in its own generated Makefile", :io do
  RENAME_SCHEMA_FIXTURE_BASENAME = "project_deploy_rename_schema_spec_fixture".freeze

  before(:context) do
    root = File.expand_path("..", __dir__)
    @generated_dir = File.join(root, "deploy", RENAME_SCHEMA_FIXTURE_BASENAME)

    Dir.mktmpdir do |dir|
      domain_dir = File.join(dir, RENAME_SCHEMA_FIXTURE_BASENAME)
      bluebook_dir = File.join(domain_dir, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)

      File.write(File.join(bluebook_dir, "#{RENAME_SCHEMA_FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
        Hecks.bluebook "Scratch" do
          aggregate "Thing" do
            identified_by :name
            attribute :name, ThingName
            value_object "ThingName" do
              attribute :value, String
              invariant("named") { !value.to_s.empty? }
            end
            command "Create" do
              attribute :name, ThingName
              sets :name
              emits "ThingCreated"
            end
          end
        end
      BLUEBOOK

      File.write(File.join(bluebook_dir, "#{RENAME_SCHEMA_FIXTURE_BASENAME}.world"), <<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsLambda") do
            region "us-east-1"
          end
        end
      WORLD

      _stdout, stderr, status = ProjectDeployRunner.run(domain_dir, root: root)
      status.success? or raise "hecks deploy project failed: #{stderr}"
    end

    @makefile = File.read(File.join(@generated_dir, "Makefile"))
  end

  after(:context) { FileUtils.rm_rf(@generated_dir) }

  # Stops at the next top-level target, not the next non-whitespace line: recipe comments start
  # with `#`.
  def rename_schema_recipe
    @makefile[/^rename-schema:\n(.*?)(?=^[A-Za-z_][A-Za-z0-9_.-]*:)/m, 1] or
      raise "no rename-schema recipe found in the generated Makefile"
  end

  SAFE_SCHEMA_NAMES = %w[old_schema NewSchema _leading_underscore a Z9 tenant_42].freeze

  UNSAFE_SCHEMA_NAMES = [
    %(bad"; DROP SCHEMA public CASCADE; --),
    "bad name with spaces",
    "bad;rm -rf /",
    "bad'name",
    "$(touch pwned)",
    "1leading_digit",
    "",
    "bad-dash"
  ].freeze

  # What the recipe must contain for the order check to mean anything, by position name.
  RECIPE_PARTS = { guard_old: "expected an OLD identifier-shape guard in the rename-schema recipe",
                   guard_new: "expected a NEW identifier-shape guard in the rename-schema recipe",
                   nspname:   "fixture's own recipe shape changed -- no nspname lookup found",
                   alter:     "fixture's own recipe shape changed -- no ALTER SCHEMA found" }.freeze

  # Where each guard and each use of the schema names sits in the recipe's commands. Commands only:
  # the guard's own leading comment names `nspname`/`ALTER SCHEMA` and would look like an earlier use.
  def recipe_positions
    recipe = rename_schema_recipe.lines.reject { |line| line.lstrip.start_with?("#") }.join
    { guard_old: recipe.index(/invalid OLD schema name/), guard_new: recipe.index(/invalid NEW schema name/),
      nspname: recipe.index("nspname"), alter: recipe.index("ALTER SCHEMA") }
  end

  # The regex the recipe's grep actually runs; `$$` is Make's escape for `$`.
  def shipped_pattern
    raw_pattern = rename_schema_recipe[/grep -Eq '(\^\[A-Za-z_\]\[A-Za-z0-9_\]\*\$\$)'/, 1]
    expect(raw_pattern).not_to be_nil, "couldn't find the identifier pattern in the generated recipe"
    Regexp.new(raw_pattern.sub(/\$\$\z/, "$"))
  end

  it "has an identifier-shape guard for OLD and NEW, and the statements they protect" do
    positions = recipe_positions

    expect(RECIPE_PARTS.reject { |key, _| positions[key] }.values).to be_empty
  end

  it "gates the recipe on an OLD/NEW identifier-shape check before either reaches SQL" do
    positions = recipe_positions
    guards = positions.values_at(:guard_old, :guard_new)

    expect(guards.product(positions.values_at(:nspname, :alter)).map { |guard, use| guard < use }).to all(be(true))
  end

  # Make substitutes $(old) into the recipe before the shell parses it, so a `"` or `;` would
  # escape the guard. $$OLD/$$NEW reach the shell as opaque env vars (make exports CLI vars).
  it "reads OLD/NEW as real shell environment variables for the guard, not Make-spliced text", :aggregate_failures do
    guard_lines = rename_schema_recipe.lines.select { |line| line.include?("grep -Eq") }

    expect(guard_lines.size).to eq(2)
    expect(guard_lines.map { |line| line[/echo "(.*?)" \| grep -Eq/, 1] }).to all(match(/\A\$\$(OLD|NEW)\z/))
  end

  it "extracts the identifier pattern actually shipped and confirms it accepts safe schema names" do
    pattern = shipped_pattern

    expect(SAFE_SCHEMA_NAMES.grep_v(pattern)).to be_empty
  end

  it "extracts the identifier pattern actually shipped and confirms it rejects unsafe schema names" do
    pattern = shipped_pattern

    expect(UNSAFE_SCHEMA_NAMES.grep(pattern)).to be_empty
  end
end
