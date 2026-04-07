// Hecks Web Console — Component module loader
// ES module entry point. Imports register all custom elements in dependency order.
// Exposes buildSections globally for inline sidebar script.
import './shared.js';
import './section_panel.js';
import './graph_layout.js';
import './svg_helpers.js';
import './filter_bar.js';
import { buildSections } from './agg_card.js';
import './domain_diagram.js';

window.buildSections = buildSections;
