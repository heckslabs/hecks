require "spec_helper"
require "hecks/projections"
require "hecks/ports/persistence/plugins/era"

# Every domain projection runs on every example domain and answers something, so a projection
# that raises on a shape no committed output happens to hold fails here. What each answers is
# held byte for byte only where a drift spec owns committed output (see `DRIFT_SPECS` in
# spec/categories/coverage_spec.rb); this loop asks only that it projects.
RSpec.describe "every domain projection, on every example domain", :aggregate_failures do
  def self.domains = Hecks::Corpus.members(:example).map(&:path).sort

  # The `site_*` projections project a site project, one that attaches the Site bluebook, not
  # any domain; spec/site_*_spec.rb hold them against the site fixture.
  def self.site_kind?(kind) = kind.to_s.start_with?("site_")

  def self.kinds = Hecks::Projector.registered_by_category.fetch(:projection).reject { |kind| site_kind?(kind) }

  def projected(dir, kind)
    registry = Hecks::Runtime::Loader.describe(dir, environment: nil).registry
    Hecks::Projector.call(kind, bluebook: registry.bluebooks.values.first, options: {})
  end

  domains.each do |dir|
    kinds.each do |kind|
      it "projects #{File.basename(dir)} as #{kind}" do
        expect(projected(dir, kind)).not_to be_nil
      end
    end
  end
end
