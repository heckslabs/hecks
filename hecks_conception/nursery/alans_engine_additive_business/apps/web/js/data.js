/* Mock data from bluebook fixtures
   Every object maps to a domain aggregate with real domain language */

const BRANDS = [
  { name: "DuraLube", key: "duralube", description: "Advanced engine treatment and protection", owned_word: "durability", differentiator: "advanced anti-wear chemistry", accent: "#3b82f6" },
  { name: "MotorKote", key: "motorkote", description: "Anti-friction engine treatment", owned_word: "anti-friction", differentiator: "hyper-lubricant metal treatment", accent: "#ef4444" },
  { name: "Slick 50", key: "slick50", description: "Engine treatment with PTFE technology", owned_word: "PTFE protection", differentiator: "original PTFE engine treatment pioneer", accent: "#f59e0b" }
];

const PERSONAS = [
  { name: "Weekend Warrior", segment: "DIY Enthusiast", age_range: "25-45", vehicle_type: "truck/muscle car", trust_source: "YouTube reviews", price_sensitivity: "high" },
  { name: "Fleet Manager", segment: "Commercial B2B", age_range: "35-55", vehicle_type: "mixed fleet", trust_source: "ASTM data and field trials", price_sensitivity: "medium" },
  { name: "High-Mileage Hero", segment: "Maintenance Buyer", age_range: "35-65", vehicle_type: "sedan/SUV", trust_source: "Amazon reviews", price_sensitivity: "high" },
  { name: "Performance Junkie", segment: "Enthusiast", age_range: "20-40", vehicle_type: "sports car/modified", trust_source: "dyno results and forums", price_sensitivity: "low" },
  { name: "Worried Parent", segment: "Mainstream Consumer", age_range: "30-50", vehicle_type: "minivan/SUV", trust_source: "brand name", price_sensitivity: "medium" },
  { name: "Professional Mechanic", segment: "Trade Professional", age_range: "25-60", vehicle_type: "customer vehicles", trust_source: "ASTM data and COA", price_sensitivity: "medium" }
];

const LAB_TESTS = [
  { codename: "EXP-2026-001", method: "ASTM D4172 Four-Ball Wear", spec: "Wear scar < 0.45mm", result: "0.38mm", pass: true },
  { codename: "EXP-2026-001", method: "ASTM D2270 Viscosity Index", spec: "VI > 140", result: "156", pass: true },
  { codename: "EXP-2026-001", method: "ASTM D97 Pour Point", spec: "< -35C", result: "-42C", pass: true },
  { codename: "EXP-2026-001", method: "ASTM D92 Flash Point", spec: "> 220C", result: "234C", pass: true },
  { codename: "EXP-2026-001", method: "ASTM D2896 Total Base Number", spec: "TBN > 8.0 mgKOH/g", result: "9.2", pass: true }
];

const COMPETITORS = [
  { name: "Lucas Oil", product: "Heavy Duty Oil Stabilizer", tech: "Petroleum-based anti-wear", price: "$12.99/qt", channels: "Retail, Walmart, Amazon" },
  { name: "Royal Purple", product: "Max-Boost", tech: "Synerlec additive technology", price: "$18.99/qt", channels: "Specialty, O'Reilly, Amazon" },
  { name: "Liqui Moly", product: "MoS2 Anti-Friction", tech: "Molybdenum disulfide", price: "$15.99/300ml", channels: "European import, Amazon" },
  { name: "Sea Foam", product: "Motor Treatment", tech: "Petroleum-based cleaner", price: "$9.99/16oz", channels: "Mass retail, auto parts" },
  { name: "Marvel Mystery Oil", product: "Mystery Oil", tech: "Mineral oil lubricant", price: "$7.99/qt", channels: "Retail, Walmart, hardware" }
];

const CHANNELS = [
  { name: "Amazon", type: "marketplace", status: "active" },
  { name: "Walmart.com", type: "marketplace", status: "active" },
  { name: "Retail", type: "brick_and_mortar", status: "active" },
  { name: "Direct", type: "website", status: "active" }
];

const PRODUCTS = [
  { sku: "DL-5W30-1QT", name: "DuraLube Engine Treatment 5W-30", brand: "duralube", price: 14.99, status: "published", in_stock: true },
  { sku: "DL-10W40-1QT", name: "DuraLube Heavy Duty 10W-40", brand: "duralube", price: 16.99, status: "published", in_stock: true },
  { sku: "MK-HYPER-1QT", name: "MotorKote Hyper Lubricant", brand: "motorkote", price: 19.99, status: "published", in_stock: true },
  { sku: "MK-FUEL-12OZ", name: "MotorKote Fuel Optimizer", brand: "motorkote", price: 11.99, status: "published", in_stock: false },
  { sku: "S50-PTFE-1QT", name: "Slick 50 Recharged Engine Treatment", brand: "slick50", price: 12.99, status: "published", in_stock: true },
  { sku: "S50-HMLG-1QT", name: "Slick 50 High Mileage Treatment", brand: "slick50", price: 14.99, status: "draft", in_stock: true },
  { sku: "DL-DIESEL-1GAL", name: "DuraLube Diesel Treatment", brand: "duralube", price: 34.99, status: "published", in_stock: true },
  { sku: "MK-TRANS-1QT", name: "MotorKote Transmission Treatment", brand: "motorkote", price: 22.99, status: "published", in_stock: true }
];

const ORDERS = [
  { number: "ORD-2026-0847", customer: "AutoZone #4412", channel: "Retail", items: 3, total: 449.70, status: "shipped" },
  { number: "ORD-2026-0848", customer: "Jim Henderson", channel: "Direct", items: 1, total: 14.99, status: "confirmed" },
  { number: "ORD-2026-0849", customer: "Walmart DC #7831", channel: "Walmart.com", items: 48, total: 2879.52, status: "fulfilling" },
  { number: "ORD-2026-0850", customer: "Mike's Fleet Service", channel: "Direct", items: 12, total: 239.88, status: "placed" },
  { number: "ORD-2026-0851", customer: "Amazon FBA", channel: "Amazon", items: 120, total: 1798.80, status: "delivered" }
];

const SUPPLIERS = [
  { name: "Afton Chemical", type: "Additive packages", lead_time: 21, rating: 4.8, status: "approved" },
  { name: "Chevron Base Oils", type: "Group II base oil", lead_time: 14, rating: 4.9, status: "approved" },
  { name: "Berry Global", type: "HDPE bottles", lead_time: 30, rating: 4.2, status: "approved" },
  { name: "Shamrock Technologies", type: "PTFE micropowder", lead_time: 28, rating: 4.5, status: "approved" },
  { name: "Songwon Industrial", type: "Antioxidants", lead_time: 45, rating: 3.8, status: "approved" }
];

const JURISDICTIONS = [
  { name: "EPA", authority: "Environmental Protection Agency", region: "Federal" },
  { name: "California OEHHA", authority: "Office of Environmental Health Hazard Assessment", region: "California" },
  { name: "California CARB", authority: "California Air Resources Board", region: "California" },
  { name: "DOT", authority: "Department of Transportation", region: "Federal" }
];
