# The helpers the charter examples share: the Tickets CLI over a Memory boot, one epic, the
# owner's rank, the product owner's rank and the tier the store holds.
module EpicCharterHelpers
  def hecks = @hecks ||= boot_hecks_in_memory

  def cli(*argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv]).first
  end

  def epic = cli("epic.open!", "epic.value=e1", "title.value=Epic e1", "outcome.value=It is carried out")

  def rank(tier, *fields) = cli("epic.rank!", "to=e1", "tier=#{tier}", *fields)

  def rerank(tier, *fields) = cli("epic.rerank!", "to=e1", "tier=#{tier}", *fields)

  def tier_of
    aggregate = hecks.registry.bluebook("Tickets").aggregates.find { |declared| declared.hecks_name == "Epic" }
    hecks.registry.repository("Tickets", aggregate).all.first.tier.value
  end
end
