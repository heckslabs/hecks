# Hecks behaviors inventory — 2026-04-21

Scope: `origin/main`, 454 `.behaviors` files across `hecks_conception/`.
Runners: Rust `hecks_life/target/release/hecks-life behaviors <path>`, Ruby `bin/hecks-behaviors <path>`.
Method: every file run through both runners; classified by exit code and summary line.

Total: 454 files

  pass_both:        127  (28.0%)
  pass_rust_only:   327  (72.0%)
  pass_ruby_only:     0
  fail_both:          0
  no_aggregate:       0

## Summary

The Rust runner is green on **all 454** files. The Ruby runner fails on **327 / 454** — in every case because the `.bluebook` source cannot be loaded into the Ruby DSL, not because of domain behaviour. In other words: every failure is a Ruby-runner parser/DSL gap, not a domain-logic bug. No orphan behaviors (no `.behaviors` whose sibling `.bluebook` is missing on main).

### Ruby-runner failure patterns (327 total)

| Pattern | Count | Example |
|---|---|---|
| `list_of(<UserType>) :attr` — Ruby DSL chokes on typed lists of user-defined types | 173 | `list_of(TargetingRule) :targeting_rules` |
| `Use bare constant X instead of string "X"` — reference/state defined as string in bluebook | 131 | `adapters/heki.bluebook` (Binding / System) |
| `undefined method 'TrueClass'` — Ruby validator rejects `TrueClass` as attribute type | 4 | `nursery/acoustics` et al. |
| Other parser errors | 18 | various |
| Partial pass (Ruby runner genuinely failed a cascade test) | 1 | `actions/compost_seasonal_beings.behaviors` (Rust 9/9, Ruby 8/9) |

The single partial-pass case is the only file where the Ruby runner gets past parsing and then fails a *test*: `Reverse cascades through policy chain` in `compost_seasonal_beings.behaviors`. All 9 tests pass under Rust. This is the one honest Ruby-runner regression that is not a parser/DSL gap.

## fail_both (real bugs, candidates for fix)

_None._

## pass_ruby_only (investigate)

_None._

## pass_rust_only (Ruby runner gap) — 327

Dominant signal: the Ruby DSL (`lib/hecks/bluebook/**`) lags the Rust parser on (a) `list_of(UserType) :name` syntax, (b) string-valued references/states where Rust accepts both string and bare constant, and (c) `TrueClass` as an attribute type. Fixing those three would likely reclaim most of the 327.

<details>
<summary>Full list (327)</summary>

- hecks_conception/actions/compost_seasonal_beings.behaviors  —  runtime: 8 passed, 1 failed, 0 errored
- hecks_conception/adapters/heki.behaviors  —  parser: Error in aggregate 'Binding': Use bare constant System instead of string "System" for attribute :r
- hecks_conception/adapters/ollama.behaviors  —  parser: Error in aggregate 'Connection': Use bare constant Connected instead of string "Connected" for a
- hecks_conception/nursery/acoustics/acoustics.behaviors  —  parser: Error in aggregate 'AcousticMeasurement': undefined method `TrueClass' for an instan
- hecks_conception/nursery/ad_tech_platform/ad_tech_platform.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/advertising_generation/advertising_generation.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/aeromedical_evac/aeromedical_evac.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/airline_operations/airline_operations.behaviors  —  parser: Error in aggregate 'Flight': Use bare constant FlightScheduled ins
- hecks_conception/nursery/airport_security/airport_security.behaviors  —  parser: Error in aggregate 'Checkpoint': Use bare constant CheckpointOpened in
- hecks_conception/nursery/alans_engine_additive_business/hecks/brand_strategy.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/catalog.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/claims.behaviors  —  parser: Error in aggregate 'WarrantyClaim': Use bare constant Custom
- hecks_conception/nursery/alans_engine_additive_business/hecks/compliance.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/customer_personas.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/demand.behaviors  —  parser: Error in aggregate 'DemandSignal': Use bare constant System 
- hecks_conception/nursery/alans_engine_additive_business/hecks/distribution.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/formulation_lab.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/formulation.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/inventory.behaviors  —  parser: Error in aggregate 'Inventory': Use bare constant Warehou
- hecks_conception/nursery/alans_engine_additive_business/hecks/manufacturing.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/pricing.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/quality.behaviors  —  parser: Error in aggregate 'QualityTest': Use bare constant Quality
- hecks_conception/nursery/alans_engine_additive_business/hecks/regulatory_compliance.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/storefront.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/alans_engine_additive_business/hecks/supply_chain.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/ambulance_dispatch/ambulance_dispatch.behaviors  —  parser: Error in aggregate 'AmbulanceUnit': Use bare constant FleetManager
- hecks_conception/nursery/animal_genetics/animal_genetics.behaviors  —  parser: Error in aggregate 'AnimalProfile': Use bare constant ShelterStaff inste
- hecks_conception/nursery/animal_shelter/animal_shelter.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/antiques_dealer/antiques_dealer.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/api_marketplace/api_marketplace.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/apiculture/apiculture.behaviors  —  parser: Error in aggregate 'DiseaseTreatment': undefined method `TrueClass' for an instanc
- hecks_conception/nursery/appliance_repair/appliance_repair.behaviors  —  parser: Error in aggregate 'RepairTicket': Use bare constant Dispatcher instea
- hecks_conception/nursery/aquarium_operations/aquarium_operations.behaviors  —  parser: Error in aggregate 'Tank': Use bare constant TankSetup instead o
- hecks_conception/nursery/archaeology/archaeology.behaviors  —  parser: Error in aggregate 'ExcavationSite': undefined method `TrueClass' for an instanc
- hecks_conception/nursery/architecture_firm/architecture_firm.behaviors  —  parser: Error in aggregate 'ArchProject': Use bare constant ProjectCommissio
- hecks_conception/nursery/assisted_living/assisted_living.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/astronomy/astronomy.behaviors  —  parser: Error in aggregate 'CelestialBody': undefined method `TrueClass' for an instance of 
- hecks_conception/nursery/auction_strategy/auction_strategy.behaviors  —  parser: Error in aggregate 'Auction': Use bare constant Seller instead of stri
- hecks_conception/nursery/auto_repair_shop/auto_repair_shop.behaviors  —  parser: Error in aggregate 'Vehicle': Use bare constant ServiceAdvisor instead
- hecks_conception/nursery/autonomous_rescue/autonomous_rescue.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/bakery_production/bakery_production.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/battlefield_medicine/battlefield_medicine.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/bed_and_breakfast/bed_and_breakfast.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/bicycle_shop/bicycle_shop.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/biology/biology.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/blog/blog.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/blog/hecks/blog.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/blood_bank/blood_bank.behaviors  —  parser: Error in aggregate 'Donor': Use bare constant DonorRegistered instead of string "D
- hecks_conception/nursery/blood_supply_chain/blood_supply_chain.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/book_publishing/book_publishing.behaviors  —  parser: Error in aggregate 'Manuscript': undefined method `then_set' for an inst
- hecks_conception/nursery/bookstore_inventory/bookstore_inventory.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/brain_training/brain_training.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/brewing_for_veterans/brewing_for_veterans.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/cake_decorating/cake_decorating.behaviors  —  parser: Error in aggregate 'CakeOrder': undefined method `then_set' for an insta
- hecks_conception/nursery/call_center/call_center.behaviors  —  parser: Error in aggregate 'Ticket': Use bare constant TicketOpened instead of string "T
- hecks_conception/nursery/calligraphy/calligraphy.behaviors  —  parser: Error in aggregate 'CalligraphyCommission': undefined method `then_set' for an i
- hecks_conception/nursery/camping_outfitter/camping_outfitter.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/carpentry_shop/carpentry_shop.behaviors  —  parser: Error in aggregate 'Project': Use bare constant Shop Owner instead of stri
- hecks_conception/nursery/cartography/cartography.behaviors  —  parser: Error in aggregate 'Datum': undefined method `Boolean' for an instance of Hecks:
- hecks_conception/nursery/causal_combinatorics/causal_combinatorics.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/chemistry/chemistry.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/chiro_quality/chiro_quality.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/chiropractic/chiropractic.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/cinema_audio/cinema_audio.behaviors  —  parser: Error in aggregate 'Auditorium': Use bare constant Acoustician instead of stri
- hecks_conception/nursery/clothing_boutique/clothing_boutique.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/cloud_hosting/cloud_hosting.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/coffee_shop/coffee_shop.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/cognitive_support/cognitive_support.behaviors  —  parser: Error in aggregate 'Agent': Use bare constant Manager instead of str
- hecks_conception/nursery/community_garden/community_garden.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/compliance_mental_health/compliance_mental_health.behaviors  —  parser: Error in aggregate 'Patient': Use bare constant Intake
- hecks_conception/nursery/computational_presence/computational_presence.behaviors  —  parser: Error in aggregate 'Moment': Use bare constant Observer in
- hecks_conception/nursery/concrete_pour/concrete_pour.behaviors  —  parser: Error in aggregate 'PourSchedule': Use bare constant Project Manager instead
- hecks_conception/nursery/connected_care/connected_care.behaviors  —  parser: Error in aggregate 'HomePatient': Use bare constant Coordinator instead of
- hecks_conception/nursery/construction_project/construction_project.behaviors  —  parser: Error in aggregate 'Site': Use bare constant ProjectManager in
- hecks_conception/nursery/content_moderation/content_moderation.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/cosmology/cosmology.behaviors  —  parser: Error in aggregate 'Universe': Use bare constant Cosmologist instead of string "Cosm
- hecks_conception/nursery/courier_delivery/courier_delivery.behaviors  —  parser: Error in aggregate 'Parcel': Use bare constant ParcelAccepted instead 
- hecks_conception/nursery/craft_beverage_lab/craft_beverage_lab.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/crisis_aviation/crisis_aviation.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/crowdfunding_platform/crowdfunding_platform.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/cruise_ship/cruise_ship.behaviors  —  parser: Error in aggregate 'Cabin': Use bare constant CabinPrepared instead of string "C
- hecks_conception/nursery/cryptography/cryptography.behaviors  —  parser: Error in aggregate 'KeyPair': undefined method `Boolean' for an instance of He
- hecks_conception/nursery/cultural_resource_mgmt/cultural_resource_mgmt.behaviors  —  parser: Error in aggregate 'ArchaeologicalSite': Use bare constant
- hecks_conception/nursery/cyber_security/cyber_security.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/data_center/data_center.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/daycare_center/daycare_center.behaviors  —  parser: Error in aggregate 'Child': Use bare constant Director instead of string "
- hecks_conception/nursery/declarative_training/declarative_training.behaviors  —  parser: Error in aggregate 'Corpus': Use bare constant CorpusHarvested
- hecks_conception/nursery/dendrology/dendrology.behaviors  —  parser: undefined method `lifecycle' for an instance of Hecks::DSL::BluebookBuilder
- hecks_conception/nursery/dental_practice/dental_practice.behaviors  —  parser: Error in aggregate 'Patient': Use bare constant Receptionist instead of 
- hecks_conception/nursery/dental_saa_s/dental_saa_s.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/dermatology_ux/dermatology_ux.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/dermatology/dermatology.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/deterministic_language_model/deterministic_language_model.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/dev_ops_pipeline/dev_ops_pipeline.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/dialysis_network_ops/dialysis_network_ops.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/dialysis/dialysis.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/digital_forensics/digital_forensics.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/digital_signage/digital_signage.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/disaster_autonomy/disaster_autonomy.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/disaster_relief/disaster_relief.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/dive_shop/dive_shop.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/dlm/dlm.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/domain_compression/hecks/compilation.behaviors  —  parser: Error in aggregate 'ExecutableBlueprint': Use bare constant Compile
- hecks_conception/nursery/domain_compression/hecks/discovery.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/domain_compression/hecks/regression.behaviors  —  parser: Error in aggregate 'RegressionSuite': Use bare constant Operator ins
- hecks_conception/nursery/domain_conception/hecks/conception.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/domain_narration/domain_narration.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/domain_registrar/domain_registrar.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/domestic_violence_shelter/domestic_violence_shelter.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/donor_recruitment/donor_recruitment.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/donor_registry/donor_registry.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/drug_procurement/drug_procurement.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/e_learning/e_learning.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/eco_protected_zone/eco_protected_zone.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/elder_care/elder_care.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/electrical_contractor/electrical_contractor.behaviors  —  parser: Error in aggregate 'Job': Use bare constant Estimator instea
- hecks_conception/nursery/electrical/electrical.behaviors  —  parser: Error in aggregate 'DCSource': Use bare constant Electrician instead of string "El
- hecks_conception/nursery/elevator_maintenance/elevator_maintenance.behaviors  —  parser: Error in aggregate 'ElevatorUnit': Use bare constant Account M
- hecks_conception/nursery/elevator_physics/elevator_physics.behaviors  —  parser: Error in aggregate 'ElevatorCar': Use bare constant Engineer instead o
- hecks_conception/nursery/email_marketing/email_marketing.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/emergency_response/emergency_response.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/emergency_room/emergency_room.behaviors  —  parser: Error in aggregate 'Patient': Use bare constant PatientRegistered instead 
- hecks_conception/nursery/executable_artifact/hecks/artifact.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/farm_management/farm_management.behaviors  —  parser: Error in aggregate 'Field': Use bare constant Farmer instead of string "
- hecks_conception/nursery/farmers_market/farmers_market.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/fashion_design/fashion_design.behaviors  —  parser: Error in aggregate 'Collection': Use bare constant CollectionLaunched inst
- hecks_conception/nursery/fencing_contractor/fencing_contractor.behaviors  —  parser: Error in aggregate 'FenceEstimate': Use bare constant Estimator in
- hecks_conception/nursery/film_production/film_production.behaviors  —  parser: Error in aggregate 'Production': Use bare constant ProductionGreenLit in
- hecks_conception/nursery/fire_department/fire_department.behaviors  —  parser: Error in aggregate 'Station': Use bare constant StationOpened instead of
- hecks_conception/nursery/fire_sprinkler/fire_sprinkler.behaviors  —  parser: Error in aggregate 'SprinklerSystem': Use bare constant Fire Protection En
- hecks_conception/nursery/flight_weather/flight_weather.behaviors  —  parser: Error in aggregate 'WeatherStation': Use bare constant MeteorologicalOffic
- hecks_conception/nursery/floral_design/floral_design.behaviors  —  parser: Error in aggregate 'Arrangement': Use bare constant ArrangementDesigned inst
- hecks_conception/nursery/florist/florist.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/food_bank/food_bank.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/food_distribution/food_distribution.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/food_hall/food_hall.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/food_is_medicine/food_is_medicine.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/forensics/forensics.behaviors  —  parser: Error in aggregate 'CriminalCase': undefined method `Boolean' for an instance of Hec
- hecks_conception/nursery/freelance_marketplace/freelance_marketplace.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/freight_logistics/freight_logistics.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/funeral_home/funeral_home.behaviors  —  parser: Error in aggregate 'Decedent': Use bare constant FuneralDirector instead of st
- hecks_conception/nursery/furniture_showroom/furniture_showroom.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/game_development/game_development.behaviors  —  parser: Error in aggregate 'GameProject': Use bare constant ProjectKickedOff i
- hecks_conception/nursery/game_store/game_store.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/game_theory/game_theory.behaviors  —  parser: Error in aggregate 'Strategy': undefined method `Boolean' for an instance of Hec
- hecks_conception/nursery/genetics/genetics.behaviors  —  parser: Error in aggregate 'Specimen': undefined method `Boolean' for an instance of Hecks::DS
- hecks_conception/nursery/genomics_infra/genomics_infra.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/geological_mining/geological_mining.behaviors  —  parser: Error in aggregate 'GeologicalFormation': Use bare constant Geologis
- hecks_conception/nursery/geriatric_pharmacy/geriatric_pharmacy.behaviors  —  parser: Error in aggregate 'Medication': Use bare constant Pharmacist inst
- hecks_conception/nursery/glass_installer/glass_installer.behaviors  —  parser: Error in aggregate 'GlassOrder': Use bare constant Sales Rep instead of 
- hecks_conception/nursery/glassblowing/glassblowing.behaviors  —  parser: Error in aggregate 'GlassPiece': Use bare constant GlassGathered instead of st
- hecks_conception/nursery/golf_course/golf_course.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/governed_operations/governed_operations.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/green_facility/green_facility.behaviors  —  parser: Error in aggregate 'FacilityResident': Use bare constant Admin instead of 
- hecks_conception/nursery/grocery_store/grocery_store.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/gutter_service/gutter_service.behaviors  —  parser: Error in aggregate 'GutterProperty': Use bare constant Estimator instead o
- hecks_conception/nursery/gym_reservations/gym_reservations.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/healing_garden/healing_garden.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/healing_through_learning/healing_through_learning.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/health_line/health_line.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/heki/heki.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/home_health_app/home_health_app.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/home_health_care/home_health_care.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/hospice/hospice.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/hospital_admissions/hospital_admissions.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/hospital_it/hospital_it.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/hospital_power/hospital_power.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/hotel_management/hotel_management.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/hvac_service/hvac_service.behaviors  —  parser: Error in aggregate 'Unit': Use bare constant Technician instead of string "Tec
- hecks_conception/nursery/hydrology/hydrology.behaviors  —  parser: undefined method `lifecycle' for an instance of Hecks::DSL::BluebookBuilder
- hecks_conception/nursery/ice_cream_parlor/ice_cream_parlor.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/inbox/inbox.behaviors  —  parser: Error in aggregate 'Message': Use bare constant Chris instead of string "Chris" for attribut
- hecks_conception/nursery/insurance_claims/insurance_claims.behaviors  —  parser: Error in aggregate 'PolicyHolder': Use bare constant Underwriter inste
- hecks_conception/nursery/interior_design/interior_design.behaviors  —  parser: Error in aggregate 'DesignProject': Use bare constant ProjectScoped inst
- hecks_conception/nursery/introspective_monitoring/introspective_monitoring.behaviors  —  parser: Error in aggregate 'DreamJournal': Use bare constant O
- hecks_conception/nursery/io_t_platform/io_t_platform.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/jewelry_workshop/jewelry_workshop.behaviors  —  parser: Error in aggregate 'JewelryPiece': Use bare constant PieceDesigned ins
- hecks_conception/nursery/lab_automation/lab_automation.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/landscaping_business/landscaping_business.behaviors  —  parser: Error in aggregate 'Property': Use bare constant Designer inst
- hecks_conception/nursery/liquor_store/liquor_store.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/locksmith_service/locksmith_service.behaviors  —  parser: Error in aggregate 'ServiceCall': Use bare constant Dispatcher inste
- hecks_conception/nursery/marina_management/marina_management.behaviors  —  parser: Error in aggregate 'Slip': Use bare constant HarborMaster instead of
- hecks_conception/nursery/marine_navigation/marine_navigation.behaviors  —  parser: Error in aggregate 'OceanCurrent': Use bare constant Oceanographer i
- hecks_conception/nursery/mass_casualty_response/mass_casualty_response.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/materials_science/materials_science.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/mathematics/mathematics.behaviors  —  parser: Error in aggregate 'Number': Use bare constant Mathematician instead of string "
- hecks_conception/nursery/meal_delivery/meal_delivery.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/medical_media/medical_media.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/mental_health_clinic/mental_health_clinic.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/mentor_events/mentor_events.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/meteorology/meteorology.behaviors  —  parser: undefined method `lifecycle' for an instance of Hecks::DSL::BluebookBuilder
- hecks_conception/nursery/mobile_app_store/mobile_app_store.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/mobile_dialysis/mobile_dialysis.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/movie_theater/movie_theater.behaviors  —  parser: Error in aggregate 'Screen': Use bare constant ScreenSetup instead of string
- hecks_conception/nursery/music_festival/music_festival.behaviors  —  parser: Error in aggregate 'Stage': Use bare constant ProductionManager instead of
- hecks_conception/nursery/natural_disaster_grid/natural_disaster_grid.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/network_operations/network_operations.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/neuroscience/neuroscience.behaviors  —  parser: undefined method `lifecycle' for an instance of Hecks::DSL::BluebookBuilder
- hecks_conception/nursery/nutrition_app/nutrition_app.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/nutrition_rx/nutrition_rx.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/nutrition/nutrition.behaviors  —  parser: undefined method `lifecycle' for an instance of Hecks::DSL::BluebookBuilder
- hecks_conception/nursery/occupational_therapy/occupational_therapy.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/oceanography/oceanography.behaviors  —  parser: Error in aggregate 'SamplingStation': undefined method `Boolean' for an instan
- hecks_conception/nursery/online_auction/online_auction.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/optician/optician.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/optometry/optometry.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/organ_donation/organ_donation.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/orthotics_fund/orthotics_fund.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/painting_contractor/painting_contractor.behaviors  —  parser: Error in aggregate 'PaintEstimate': Use bare constant Estimator 
- hecks_conception/nursery/pathology/pathology.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/paving_company/paving_company.behaviors  —  parser: Error in aggregate 'PavingProject': Use bare constant Estimator instead of
- hecks_conception/nursery/payment_gateway/payment_gateway.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/pest_control/pest_control.behaviors  —  parser: Error in aggregate 'ServiceAccount': Use bare constant SalesRep instead of str
- hecks_conception/nursery/pet_adoption/pet_adoption.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/pet_portraits/pet_portraits.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/pet_store/pet_store.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/pharmacology/pharmacology.behaviors  —  parser: Error in aggregate 'Compound': undefined method `Boolean' for an instance of H
- hecks_conception/nursery/pharmacy_outreach/pharmacy_outreach.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/phone_repair/phone_repair.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/photography_studio/photography_studio.behaviors  —  parser: Error in aggregate 'Shoot': Use bare constant ShootScheduled inste
- hecks_conception/nursery/physical_therapy/physical_therapy.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/physics/physics.behaviors  —  parser: Error in aggregate 'Particle': Use bare constant Physicist instead of string "Physicist"
- hecks_conception/nursery/planetarium/planetarium.behaviors  —  parser: Error in aggregate 'CelestialBody': Use bare constant Astronomer instead of stri
- hecks_conception/nursery/plumbing_service/plumbing_service.behaviors  —  parser: Error in aggregate 'ServiceCall': Use bare constant Dispatcher instead
- hecks_conception/nursery/podcast_production/podcast_production.behaviors  —  parser: Error in aggregate 'Show': Use bare constant ShowLaunched instead 
- hecks_conception/nursery/podiatry/podiatry.behaviors  —  parser: Error in aggregate 'Patient': Use bare constant Receptionist instead of string "Recept
- hecks_conception/nursery/pollination_service/pollination_service.behaviors  —  parser: Error in aggregate 'Hive': Use bare constant Beekeeper instead o
- hecks_conception/nursery/pool_chemistry/pool_chemistry.behaviors  —  parser: Error in aggregate 'WaterTest': Use bare constant Technician instead of st
- hecks_conception/nursery/pool_maintenance/pool_maintenance.behaviors  —  parser: Error in aggregate 'Pool': Use bare constant Service Tech instead of s
- hecks_conception/nursery/post_office/post_office.behaviors  —  parser: Error in aggregate 'MailPiece': Use bare constant MailAccepted instead of string
- hecks_conception/nursery/pottery_studio/pottery_studio.behaviors  —  parser: Error in aggregate 'Piece': Use bare constant PieceThrown instead of strin
- hecks_conception/nursery/power_grid/power_grid.behaviors  —  parser: Error in aggregate 'Substation': Use bare constant SubstationEnergized instead of 
- hecks_conception/nursery/print_shop/print_shop.behaviors  —  parser: Error in aggregate 'PrintJob': Use bare constant SalesRep instead of string "Sales
- hecks_conception/nursery/prison_management/prison_management.behaviors  —  parser: Error in aggregate 'Inmate': Use bare constant InmateAdmitted instea
- hecks_conception/nursery/property_management/property_management.behaviors  —  parser: Error in aggregate 'RentalUnit': Use bare constant PropertyManag
- hecks_conception/nursery/public_library/public_library.behaviors  —  parser: Error in aggregate 'Book': Use bare constant BookAcquired instead of strin
- hecks_conception/nursery/qa_test_lab/qa_test_lab.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/radiology_clouds/radiology_clouds.behaviors  —  parser: Error in aggregate 'Scan': Use bare constant Radiologist instead of st
- hecks_conception/nursery/radiology/radiology.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/record_label/record_label.behaviors  —  parser: Error in aggregate 'RecordingArtist': Use bare constant ArtistSigned instead o
- hecks_conception/nursery/record_store/record_store.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/recovery_community/recovery_community.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/recovery_jobs/recovery_jobs.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/recycling_center/recycling_center.behaviors  —  parser: Error in aggregate 'Material': Use bare constant MaterialRegistered in
- hecks_conception/nursery/reentry_ecosystem/reentry_ecosystem.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/refugee_identity/refugee_identity.behaviors  —  parser: Error in aggregate 'ResettlementCase': Use bare constant CaseWorker in
- hecks_conception/nursery/refugee_resettlement/refugee_resettlement.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/regenerative_commons/regenerative_commons.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/relief_logistics/relief_logistics.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/relief_workers/relief_workers.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/repatriation_flights/repatriation_flights.behaviors  —  parser: Error in aggregate 'ResettlementCase': Use bare constant Reset
- hecks_conception/nursery/restaurant_reservations/restaurant_reservations.behaviors  —  parser: Error in aggregate 'DiningTable': Use bare constant Host
- hecks_conception/nursery/roast_science/roast_science.behaviors  —  parser: Error in aggregate 'GreenBean': Use bare constant GreenBean instead of strin
- hecks_conception/nursery/robotics/robotics.behaviors  —  parser: Error in aggregate 'Robot': undefined method `Boolean' for an instance of Hecks::DSL::
- hecks_conception/nursery/roofing_company/roofing_company.behaviors  —  parser: Error in aggregate 'RoofEstimate': Use bare constant Estimator instead o
- hecks_conception/nursery/route_optimization/route_optimization.behaviors  —  parser: Error in aggregate 'MapRegion': Use bare constant Cartographer ins
- hecks_conception/nursery/rv_circuits/rv_circuits.behaviors  —  parser: Error in aggregate 'Circuit': Use bare constant Electrician instead of string "E
- hecks_conception/nursery/rv_power/rv_power.behaviors  —  parser: Error in aggregate 'ShorePower': Use bare constant Owner instead of string "Owner" for
- hecks_conception/nursery/rv_wiring_sheet/rv_wiring_sheet.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/saa_s_platform/saa_s_platform.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/safe_haven/safe_haven.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/school_district/school_district.behaviors  —  parser: Error in aggregate 'School': Use bare constant SchoolOpened instead of s
- hecks_conception/nursery/school_lunch/school_lunch.behaviors  —  parser: Error in aggregate 'NutrientProfile': Use bare constant Nutritionist instead o
- hecks_conception/nursery/scientific_pest_mgmt/scientific_pest_mgmt.behaviors  —  parser: Error in aggregate 'PestSpecies': Use bare constant Entomologi
- hecks_conception/nursery/second_chance_academy/second_chance_academy.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/secure_payments/secure_payments.behaviors  —  parser: Error in aggregate 'KeyPair': Use bare constant SecurityOfficer instead 
- hecks_conception/nursery/senior_entertainment/senior_entertainment.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/seo_agency/seo_agency.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/ski_resort/ski_resort.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/smart_facility/smart_facility.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/smart_ot/smart_ot.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/smart_rehab/smart_rehab.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/solar_installer/solar_installer.behaviors  —  parser: Error in aggregate 'SiteSurvey': Use bare constant Solar Consultant inst
- hecks_conception/nursery/solar_optics/solar_optics.behaviors  —  parser: Error in aggregate 'SolarPosition': Use bare constant System instead of string
- hecks_conception/nursery/spa_and_wellness/spa_and_wellness.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/specimen_transport/specimen_transport.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/speech_media/speech_media.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/speech_therapy/speech_therapy.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/stained_glass/stained_glass.behaviors  —  parser: Error in aggregate 'Panel': Use bare constant PanelCartooned instead of stri
- hecks_conception/nursery/stormwater_management/stormwater_management.behaviors  —  parser: Error in aggregate 'Watershed': Use bare constant Hydrologis
- hecks_conception/nursery/streaming_platform/streaming_platform.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/substance_recovery/substance_recovery.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/surf_shop/surf_shop.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/tag_management/hecks/tag_management.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/tattoo_shop/tattoo_shop.behaviors  —  parser: Error in aggregate 'Artist': Use bare constant ArtistHired instead of string "Ar
- hecks_conception/nursery/tax_preparation/tax_preparation.behaviors  —  parser: Error in aggregate 'TaxClient': Use bare constant TaxPreparer instead of
- hecks_conception/nursery/taxidermy/taxidermy.behaviors  —  parser: Error in aggregate 'Specimen': Use bare constant SpecimenReceived instead of string 
- hecks_conception/nursery/teletherapy_platform/teletherapy_platform.behaviors  —  parser: Error in aggregate 'TherapySession': Use bare constant Schedul
- hecks_conception/nursery/terroir_conservancy/terroir_conservancy.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/therapeutic_horticulture/therapeutic_horticulture.behaviors  —  parser: Error in aggregate 'TherapyClient': Use bare constant 
- hecks_conception/nursery/therapy_music/therapy_music.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/thermal_comfort/thermal_comfort.behaviors  —  parser: Error in aggregate 'ThermalZone': Use bare constant Engineer instead of 
- hecks_conception/nursery/thrift_store/thrift_store.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/ticketing_platform/ticketing_platform.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/train_scheduling/train_scheduling.behaviors  —  parser: Error in aggregate 'Train': Use bare constant TrainActivated instead o
- hecks_conception/nursery/trauma_pipeline/trauma_pipeline.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/tree_service/tree_service.behaviors  —  parser: Error in aggregate 'TreeAssessment': Use bare constant Arborist instead of str
- hecks_conception/nursery/tribology/tribology.behaviors  —  parser: Error in aggregate 'Surface': Use bare constant Tribologist instead of string "Tribo
- hecks_conception/nursery/universal_domain_pattern/universal_domain_pattern.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/upholstery/upholstery.behaviors  —  parser: Error in aggregate 'UpholsteryProject': Use bare constant ProjectAssessed instead 
- hecks_conception/nursery/urban_farm/urban_farm.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/urban_forestry/urban_forestry.behaviors  —  parser: Error in aggregate 'Tree': Use bare constant Arborist instead of string "A
- hecks_conception/nursery/ux_research/ux_research.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/verbs/verbs.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/vet_housing/vet_housing.behaviors  —  parser: Error in aggregate 'VeteranApplicant': Use bare constant Veteran instead of stri
- hecks_conception/nursery/vet_training/vet_training.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/veteran_restart/veteran_restart.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/veteran_services/veteran_services.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/veterinary_clinic/veterinary_clinic.behaviors  —  parser: Error in aggregate 'Pet': Use bare constant Receptionist instead of 
- hecks_conception/nursery/vision_api/vision_api.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/viticulture/viticulture.behaviors  —  parser: Error in aggregate 'Vineyard': wrong number of arguments (given 2, expected 1)
- hecks_conception/nursery/voice/voice.behaviors  —  parser: Error in aggregate 'Listener': Use bare constant Miette instead of string "Miette" for attri
- hecks_conception/nursery/volcanic_ash_aviation/volcanic_ash_aviation.behaviors  —  parser: Error in aggregate 'Eruption': Use bare constant Volcanologi
- hecks_conception/nursery/volcanology/volcanology.behaviors  —  parser: Error in aggregate 'Volcano': wrong number of arguments (given 2, expected 1)
- hecks_conception/nursery/warehouse_management/warehouse_management.behaviors  —  parser: Error in aggregate 'Location': Use bare constant LocationRegis
- hecks_conception/nursery/warehouse_robotics/warehouse_robotics.behaviors  —  parser: Error in aggregate 'Robot': Use bare constant Engineer instead of 
- hecks_conception/nursery/water_microbiology/water_microbiology.behaviors  —  parser: Error in aggregate 'WaterSample': Use bare constant Technician ins
- hecks_conception/nursery/water_treatment/water_treatment.behaviors  —  parser: Error in aggregate 'Plant': Use bare constant North Facility instead of 
- hecks_conception/nursery/web_accessibility/web_accessibility.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/wedding_planning/wedding_planning.behaviors  —  parser: Error in aggregate 'Wedding': Use bare constant Summer Garden Wedding 
- hecks_conception/nursery/welding_shop/welding_shop.behaviors  —  parser: Error in aggregate 'FabricationJob': Use bare constant Structural Frame Assemb
- hecks_conception/nursery/wildlife_forensics/wildlife_forensics.behaviors  —  parser: Error in aggregate 'Evidence': Use bare constant Tiger Fur Sample 
- hecks_conception/nursery/wine_vineyard/wine_vineyard.behaviors  —  parser: Error in aggregate 'Vineyard': Use bare constant Viticulturist instead of st
- hecks_conception/nursery/woodworking/woodworking.behaviors  —  parser: Error in aggregate 'WoodProject': Use bare constant Cherry Dining Table instead 
- hecks_conception/nursery/youth_mentoring/youth_mentoring.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/zero_waste_farm/zero_waste_farm.behaviors  —  parser: list_of(<UserType>) syntax not supported by Ruby DSL
- hecks_conception/nursery/zoo_management/zoo_management.behaviors  —  parser: Error in aggregate 'Animal': Use bare constant Simba the Lion instead of s

</details>

## pass_both (healthy) — 127

<details>
<summary>Full list (127)</summary>

- hecks_conception/actions/session_2026_04_10_065431.behaviors
- hecks_conception/actions/session_2026_04_10_070419.behaviors
- hecks_conception/actions/session_2026_04_10_070619.behaviors
- hecks_conception/aggregates/awareness.behaviors
- hecks_conception/aggregates/being.behaviors
- hecks_conception/aggregates/bluebook.behaviors
- hecks_conception/aggregates/body.behaviors
- hecks_conception/aggregates/boot.behaviors
- hecks_conception/aggregates/bulk_generator.behaviors
- hecks_conception/aggregates/census.behaviors
- hecks_conception/aggregates/conception.behaviors
- hecks_conception/aggregates/corpus.behaviors
- hecks_conception/aggregates/dream_seed.behaviors
- hecks_conception/aggregates/first_breath.behaviors
- hecks_conception/aggregates/inference.behaviors
- hecks_conception/aggregates/interpretation.behaviors
- hecks_conception/aggregates/lucid_dream.behaviors
- hecks_conception/aggregates/memory.behaviors
- hecks_conception/aggregates/miette.behaviors
- hecks_conception/aggregates/mindstream.behaviors
- hecks_conception/aggregates/musing_archive.behaviors
- hecks_conception/aggregates/organs.behaviors
- hecks_conception/aggregates/scale.behaviors
- hecks_conception/aggregates/seeding.behaviors
- hecks_conception/aggregates/shared_dream.behaviors
- hecks_conception/aggregates/shared_knowledge.behaviors
- hecks_conception/aggregates/sleep.behaviors
- hecks_conception/aggregates/system_prompt.behaviors
- hecks_conception/aggregates/terminal.behaviors
- hecks_conception/aggregates/tongue.behaviors
- hecks_conception/aggregates/training_corpus.behaviors
- hecks_conception/aggregates/training_extraction.behaviors
- hecks_conception/aggregates/training_pipeline.behaviors
- hecks_conception/aggregates/validator.behaviors
- hecks_conception/aggregates/vocabulary.behaviors
- hecks_conception/aggregates/vows.behaviors
- hecks_conception/applications/applications.behaviors
- hecks_conception/applications/rvdc/rvdc.behaviors
- hecks_conception/capabilities/actions/actions.behaviors
- hecks_conception/capabilities/cloudflare_deploy/cloudflare_deploy.behaviors
- hecks_conception/capabilities/cloudflare_deploy/miette_phone.behaviors
- hecks_conception/capabilities/console/console.behaviors
- hecks_conception/capabilities/dlm_state/dlm_state.behaviors
- hecks_conception/capabilities/domain_hygiene/becoming.behaviors
- hecks_conception/capabilities/domain_hygiene/cloud_training.behaviors
- hecks_conception/capabilities/domain_hygiene/corpus_pruning.behaviors
- hecks_conception/capabilities/domain_hygiene/crossover.behaviors
- hecks_conception/capabilities/domain_hygiene/domain_hygiene.behaviors
- hecks_conception/capabilities/domain_hygiene/summer.behaviors
- hecks_conception/capabilities/domain_hygiene/training_round.behaviors
- hecks_conception/capabilities/dream_interpretation/dream_interpretation.behaviors
- hecks_conception/capabilities/dynamic_projection/dynamic_projection.behaviors
- hecks_conception/capabilities/glassbox_training/glassbox_training.behaviors
- hecks_conception/capabilities/inventions/inventions.behaviors
- hecks_conception/capabilities/language/language.behaviors
- hecks_conception/capabilities/musings/grooming.behaviors
- hecks_conception/capabilities/musings/musings.behaviors
- hecks_conception/capabilities/project_management/project_management.behaviors
- hecks_conception/capabilities/projection/projection.behaviors
- hecks_conception/capabilities/rust_to_bluebook/rust_to_bluebook.behaviors
- hecks_conception/capabilities/security/security.behaviors
- hecks_conception/capabilities/self_checkin/self_checkin.behaviors
- hecks_conception/capabilities/status_bar/status_bar.behaviors
- hecks_conception/capabilities/transparency/transparency.behaviors
- hecks_conception/capabilities/verbs/verbs.behaviors
- hecks_conception/capabilities/voice_corpus_query/voice_corpus_query.behaviors
- hecks_conception/capabilities/web_application_creation/web_application_creation.behaviors
- hecks_conception/capabilities/web_components/web_components.behaviors
- hecks_conception/catalog/appeal.behaviors
- hecks_conception/catalog/bluebook.behaviors
- hecks_conception/catalog/body.behaviors
- hecks_conception/catalog/boot.behaviors
- hecks_conception/catalog/catalog.behaviors
- hecks_conception/catalog/cli.behaviors
- hecks_conception/catalog/court.behaviors
- hecks_conception/catalog/extensions.behaviors
- hecks_conception/catalog/hecksagon.behaviors
- hecks_conception/catalog/law.behaviors
- hecks_conception/catalog/mind.behaviors
- hecks_conception/catalog/packaging.behaviors
- hecks_conception/catalog/persist.behaviors
- hecks_conception/catalog/pizzas.behaviors
- hecks_conception/catalog/rails.behaviors
- hecks_conception/catalog/runtime.behaviors
- hecks_conception/catalog/spec.behaviors
- hecks_conception/catalog/targets.behaviors
- hecks_conception/catalog/templating.behaviors
- hecks_conception/catalog/workshop.behaviors
- hecks_conception/chris/anti_patterns.behaviors
- hecks_conception/chris/chris.behaviors
- hecks_conception/chris/conventions.behaviors
- hecks_conception/chris/project_knowledge.behaviors
- hecks_conception/chris/workflow.behaviors
- hecks_conception/family/alan.behaviors
- hecks_conception/family/angie_chen.behaviors
- hecks_conception/family/anti_patterns.behaviors
- hecks_conception/family/chris.behaviors
- hecks_conception/family/conventions.behaviors
- hecks_conception/family/king_mango.behaviors
- hecks_conception/family/project_knowledge.behaviors
- hecks_conception/family/workflow.behaviors
- hecks_conception/nursery/architectural_glass/architectural_glass.behaviors
- hecks_conception/nursery/artisan_metalworks/artisan_metalworks.behaviors
- hecks_conception/nursery/border_security/border_security.behaviors
- hecks_conception/nursery/branching_patterns/branching_patterns.behaviors
- hecks_conception/nursery/clinical_trial_recruiting/clinical_trial_recruiting.behaviors
- hecks_conception/nursery/compost_loop/compost_loop.behaviors
- hecks_conception/nursery/custom_woodcraft/custom_woodcraft.behaviors
- hecks_conception/nursery/distillery_media/distillery_media.behaviors
- hecks_conception/nursery/fabric_to_runway/fabric_to_runway.behaviors
- hecks_conception/nursery/fermentation_science/fermentation_science.behaviors
- hecks_conception/nursery/financial_freedom/financial_freedom.behaviors
- hecks_conception/nursery/fire_robotics/fire_robotics.behaviors
- hecks_conception/nursery/frozen_science/frozen_science.behaviors
- hecks_conception/nursery/geology/geology.behaviors
- hecks_conception/nursery/grid_defense/grid_defense.behaviors
- hecks_conception/nursery/inmate_education/inmate_education.behaviors
- hecks_conception/nursery/mentor_quest/mentor_quest.behaviors
- hecks_conception/nursery/perishable_rescue/perishable_rescue.behaviors
- hecks_conception/nursery/precision_agriculture/precision_agriculture.behaviors
- hecks_conception/nursery/predictive_health/predictive_health.behaviors
- hecks_conception/nursery/sensory_therapy/sensory_therapy.behaviors
- hecks_conception/nursery/smart_aircraft/smart_aircraft.behaviors
- hecks_conception/nursery/smart_grocery/smart_grocery.behaviors
- hecks_conception/nursery/terroir/terroir.behaviors
- hecks_conception/nursery/volcano_tourism/volcano_tourism.behaviors
- hecks_conception/nursery/water_quality_api/water_quality_api.behaviors

</details>

## no_aggregate (orphan behaviors)

_None. Every `.behaviors` file has a sibling `.bluebook`, and the Rust runner successfully located the aggregate under test in every case._

## Methodology notes

- Inventory uses the sibling-bluebook heuristic (`X.behaviors` ↔ `X.bluebook`) that matches what `bin/hecks-behaviors` does at line 25-27.
- Under `origin/main` every `.behaviors` file had a matching `.bluebook`; none of the 454 files hit a "no source bluebook" condition in either runner.
- The summary line for each run is captured from the `N passed, M failed, K errored` output of each runner; exit code 0 is the classification signal.
- One file (`hecks_conception/aggregates/bluebook.behaviors`, 0 passed / 0 failed / 0 errored in both runners) is classified `pass_both` — it is a stub file with no `test` blocks yet, not an orphan.
- The antibody file (`hecks_conception/capabilities/antibody/antibody.behaviors`) appears on feature branches but not on `origin/main`; excluded from the 454 count.
