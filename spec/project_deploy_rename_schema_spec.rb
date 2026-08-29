require "tmpdir"
require "fileutils"
require "open3"

# L20 (docs/audits/2026-08-10-main-bug-audit.md): `rename-schema` used to
# interpolate `$(OLD)`/`$(NEW)` unsanitized into SQL (a `nspname = '...'`
# lookup and an `ALTER SCHEMA "..." RENAME TO "..."`) with nothing checking
# their shape first -- operator-only (this is a `make rename-schema
# OLD=<old> NEW=<new>` command line, not user-facing web input), but
# against production RDS, so a typo'd or copy-pasted value containing SQL
# metacharacters could execute unintended SQL. Fixed by allowlisting OLD
# and NEW as bare identifiers (schema names can't be bound as a SQL
# parameter the way a value can, so escaping isn't the available option --
# refusing anything that isn't `^[A-Za-z_][A-Za-z0-9_]*$` is).
#
# Like spec/project_deploy_contract_spec.rb, this tests the THING THAT
# ACTUALLY MATTERS in the real generated output, not a re-derivation of
# the same Ruby text that produced it: bin/project_deploy is a script, not
# a library (nothing to require), so the fixture below is generated once
# and its Makefile's rename-schema recipe is inspected directly, the same
# way an operator would encounter it.
RSpec.describe "bin/project_deploy's rename-schema OLD/NEW allowlist, in its own generated Makefile", :io do
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

      _stdout, stderr, status = Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir)
      status.success? or raise "bin/project_deploy failed: #{stderr}"
    end

    @makefile = File.read(File.join(@generated_dir, "Makefile"))
  end

  after(:context) { FileUtils.rm_rf(@generated_dir) }

  # Stops at the next top-level target line, not just the next
  # non-whitespace line -- the recipe's own leading comment lines start
  # with `#`, which is non-whitespace too.
  def rename_schema_recipe
    @makefile[/^rename-schema:\n(.*?)(?=^[A-Za-z_][A-Za-z0-9_.-]*:)/m, 1] or
      raise "no rename-schema recipe found in the generated Makefile"
  end

  it "gates the recipe on an OLD/NEW identifier-shape check before either reaches SQL" do
    # Only the recipe's actual commands, not its leading comment lines --
    # the comment above the guard itself explains what it protects by
    # naming `nspname`/`ALTER SCHEMA`, which would otherwise look like an
    # earlier "use" of them than the guard that runs before the real ones.
    recipe = rename_schema_recipe.lines.reject { |line| line.lstrip.start_with?("#") }.join

    guard_old = recipe.index(/invalid OLD schema name/)
    guard_new = recipe.index(/invalid NEW schema name/)
    nspname_lookup = recipe.index("nspname")
    alter_schema = recipe.index("ALTER SCHEMA")

    expect(guard_old).not_to be_nil, "expected an OLD identifier-shape guard in the rename-schema recipe"
    expect(guard_new).not_to be_nil, "expected a NEW identifier-shape guard in the rename-schema recipe"
    expect(nspname_lookup).not_to be_nil, "fixture's own recipe shape changed -- no nspname lookup found"
    expect(alter_schema).not_to be_nil, "fixture's own recipe shape changed -- no ALTER SCHEMA found"

    expect(guard_old).to be < nspname_lookup
    expect(guard_new).to be < nspname_lookup
    expect(guard_old).to be < alter_schema
    expect(guard_new).to be < alter_schema
  end

  it "reads OLD/NEW as real shell environment variables for the guard, not Make-spliced text" do
    # $(OLD)/$(NEW) is Make substituting raw text into the recipe line
    # *before* the shell ever parses it -- a value containing `"` or `;`
    # would break out of the guard's own shell command and run before the
    # pattern match sees it (confirmed live: this is exactly how it was
    # bypassable while the guard used $(OLD)/$(NEW) instead of $$OLD/$$NEW).
    # $$OLD/$$NEW is Make's escaping for a literal `$OLD`/`$NEW`, which the
    # shell resolves as one opaque environment variable regardless of its
    # contents -- `make` auto-exports command-line-assigned variables.
    recipe = rename_schema_recipe
    guard_lines = recipe.lines.select { |line| line.include?("grep -Eq") }

    expect(guard_lines.size).to eq(2)
    guard_lines.each do |line|
      value_under_test = line[/echo "(.*?)" \| grep -Eq/, 1]
      expect(value_under_test).to match(/\A\$\$(OLD|NEW)\z/),
                                  "expected the guard to test $$OLD/$$NEW (a real shell env var), " \
                                  "got #{value_under_test.inspect} in: #{line}"
    end
  end

  it "extracts the identifier pattern actually shipped and confirms it accepts safe schema names and rejects unsafe ones" do
    recipe = rename_schema_recipe
    raw_pattern = recipe[/grep -Eq '(\^\[A-Za-z_\]\[A-Za-z0-9_\]\*\$\$)'/, 1]
    expect(raw_pattern).not_to be_nil, "couldn't find the identifier pattern in the generated recipe"

    # `$$` is Make's escaping for a literal `$` (the shell/grep never sees
    # the doubled form) -- undo that to get the real regex grep runs.
    pattern = Regexp.new(raw_pattern.sub(/\$\$\z/, "$"))

    # rubocop:disable RSpec/IteratedExpectation -- each item gets its own failure message
    %w[old_schema NewSchema _leading_underscore a Z9 tenant_42].each do |safe|
      expect(safe).to match(pattern), "expected #{safe.inspect} to be accepted as a safe schema name"
    end

    [
      %(bad"; DROP SCHEMA public CASCADE; --),
      "bad name with spaces",
      "bad;rm -rf /",
      "bad'name",
      "$(touch pwned)",
      "1leading_digit",
      "",
      "bad-dash"
    ].each do |unsafe|
      expect(unsafe).not_to match(pattern), "expected #{unsafe.inspect} to be rejected as an unsafe schema name"
    end
    # rubocop:enable RSpec/IteratedExpectation
  end
end
