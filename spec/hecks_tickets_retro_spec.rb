# frozen_string_literal: true

require "spec_helper"

# scrum master has marked each one kept, folded into a principle, or dropped.
RSpec.describe "the Tickets Retro" do
  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv]).first
  end

  def agreement(key)
    cli("working_agreement.declare!", "agreement.value=#{key}", "text.value=Rule #{key}", "kind.value=practice")
  end

  def open_retro(day = "2026-11-22") = cli("retro.open!", "retro.value=#{day}")

  def review(day, key, mark, extra = [])
    cli("agreement_review.record!", "review.value=#{day}@#{key}", "retro.value=#{day}", "agreement.value=#{key}",
        "mark.value=#{mark}", *extra)
  end

  def plain(value) = value.respond_to?(:value) ? value.value : value

  def stored(name)
    declared = hecks.registry.bluebook("Tickets").aggregates.find { |found| found.hecks_name == name }
    hecks.registry.repository("Tickets", declared).all
  end

  def status_of(name, field, key) = plain(stored(name).find { |row| plain(row.public_send(field)) == key }.status)

  it "refuses to proceed to the main round when no review is recorded" do
    agreement("a1")
    open_retro
    cli("retro.proceed!", "to=2026-11-22")
    expect(status_of("Retro", :retro, "2026-11-22")).to eq("opening")
  end

  it "counts the agreements in force when the retro opens" do
    agreement("a1")
    agreement("a2")
    open_retro
    expect(plain(stored("Retro").first.unreviewed)).to eq(2)
  end

  it "retires a folded agreement under the principle it names" do
    agreement("a1")
    open_retro
    review("2026-11-22", "a1", "folded", ["principle.value=fix-together"])
    row = stored("WorkingAgreement").first
    expect([plain(row.status), plain(row.principle)]).to eq(%w[retired fix-together])
  end

  def reviewed_retro
    agreement("a1")
    open_retro
    review("2026-11-22", "a1", "kept")
    %w[retro.complete_review! retro.proceed!].each { |verb| cli(verb, "to=2026-11-22") }
  end

  it "lets the retro proceed once every agreement is reviewed" do
    reviewed_retro
    expect(status_of("Retro", :retro, "2026-11-22")).to eq("main_round")
  end

  it "keeps a kept agreement in force" do
    reviewed_retro
    expect(status_of("WorkingAgreement", :agreement, "a1")).to eq("in_force")
  end
end
