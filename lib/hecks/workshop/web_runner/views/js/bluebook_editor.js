// Hecks::Workshop::WebRunner — BluebookEditor
//
// Read-only source viewer for Bluebook DSL files. Renders Ruby DSL with
// domain-keyword syntax highlighting inside the Workshop IDE editor pane.
//
//   var ed = document.createElement('bluebook-editor');
//   ed.content = 'Hecks.domain "Pizzas" do\n  aggregate "Pizza" do\n  end\nend';
//   editorPane.appendChild(ed);
//
import { COLORS, BASE_STYLES } from './shared.js';

class BluebookEditorElement extends HTMLElement {
  connectedCallback() { this._render(); }

  set content(val) { this._content = val; this._render(); }
  get content()    { return this._content || ''; }

  _render() {
    if (!this.shadowRoot) this.attachShadow({ mode: 'open' });
    this.shadowRoot.innerHTML = `
      <style>
        ${BASE_STYLES}
        :host { display: block; height: 100%; overflow: auto; background: ${COLORS.bg}; }
        pre {
          margin: 0; padding: 16px 20px;
          font-family: "SF Mono", "Fira Code", monospace;
          font-size: 13px; line-height: 1.7; color: ${COLORS.text};
          white-space: pre; overflow-x: auto; tab-size: 2;
        }
        .kw { color: ${COLORS.blue}; }
        .st { color: ${COLORS.orange}; }
        .cm { color: ${COLORS.muted}; font-style: italic; }
        .tp { color: ${COLORS.cyan}; }
        .cn { color: ${COLORS.purple}; }
        .ns { color: ${COLORS.cyan}; font-weight: 600; }
      </style>
      <pre>${_highlight(this.content)}</pre>
    `;
  }
}

function _highlight(code) {
  return code.split('\n').map(_highlightLine).join('\n');
}

function _highlightLine(line) {
  var ci = line.indexOf('#');
  if (ci > -1) {
    return _colorTokens(_esc(line.slice(0, ci))) +
           '<span class="cm">' + _esc(line.slice(ci)) + '</span>';
  }
  return _colorTokens(_esc(line));
}

function _colorTokens(s) {
  // Strings (must run before keywords to avoid coloring inside strings)
  s = s.replace(/(&quot;[^&]*?&quot;|&#39;[^&]*?&#39;)/g, '<span class="st">$1</span>');
  // Hecks namespace
  s = s.replace(/\bHecks\b/g, '<span class="ns">Hecks</span>');
  // DSL keywords
  s = s.replace(
    /\b(aggregate|attribute|command|event|policy|entity|lifecycle|validation|reference_to|list_of|spec|query|transition|subscriber|context|do|end)\b/g,
    '<span class="kw">$1</span>'
  );
  // Built-in types
  s = s.replace(
    /\b(String|Integer|Float|TrueClass|Date|DateTime|JSON|Boolean)\b/g,
    '<span class="tp">$1</span>'
  );
  // CamelCase constants (aggregate/command names)
  s = s.replace(/\b([A-Z][a-zA-Z0-9]{2,})\b/g, '<span class="cn">$1</span>');
  return s;
}

function _esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

customElements.define('bluebook-editor', BluebookEditorElement);
