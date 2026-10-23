require "spec_helper"
require_relative "../support/domain_names"

# Every action, rule, stage and role an example domain declares appears in each projection meant
# to show it. `SHOWN_IN` is that matrix, and each kind a projection leaves out by design is in
# `NOT_SHOWN_IN` with the reason, so a new projection or kind must be placed in one or the other.
RSpec.describe "every example domain's projections, complete", :aggregate_failures do
  PROJECTIONS = %i[statements glossary forms diagrams].freeze

  # What each projection is answerable for showing, and of which commands.
  SHOWN_IN = {
    actions: { statements: :stated_actions, glossary: :actions, forms: [:actions, :aggregate], diagrams: :actions },
    rules:   { statements: :rules, glossary: :rules, forms: [:rules, :aggregate] },
    stages:  { statements: :stages, glossary: :stages, diagrams: :stages },
    roles:   { statements: :roles, glossary: :roles, forms: [:roles, :aggregate], diagrams: :roles }
  }.freeze

  # What a projection leaves out on purpose.
  NOT_SHOWN_IN = {
    rules:  { diagrams: "a diagram draws structure and moves, not the rules a command checks" },
    stages: { forms: "a form asks for a command's arguments; the record's stage is not one of them" }
  }.freeze

  def self.domains = Hecks::Corpus.members(:example).map(&:path).sort

  def missing(dir, kind, projection)
    selector, scope = SHOWN_IN.dig(kind, projection)
    names = DomainNames.new(dir)
    names.missing(kind, projection, among: scope ? names.public_send(selector, scope) : names.public_send(selector))
  end

  domains.each do |dir|
    SHOWN_IN.each do |kind, projections|
      projections.each_key do |projection|
        it "names every #{kind.to_s.chomp("s")} of #{File.basename(dir)} in its #{projection}" do
          expect(missing(dir, kind, projection)).to be_empty
        end
      end
    end
  end

  it "places every kind in every projection, shown or left out with a reason" do
    unplaced = SHOWN_IN.keys.product(PROJECTIONS).reject do |kind, projection|
      SHOWN_IN.dig(kind, projection) || NOT_SHOWN_IN.dig(kind, projection)
    end
    expect(unplaced).to be_empty
  end
end
