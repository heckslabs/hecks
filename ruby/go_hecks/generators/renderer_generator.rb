# GoHecks::RendererGenerator
#
# Generates a Go template renderer that loads html/template files
# and renders them with layout wrapping. Struct definitions for
# shared types (NavItem, FormField, etc.) come from ViewContract.
#
module GoHecks
  class RendererGenerator
    def generate
      vc = HecksTemplating::ViewContract
      structs = []

      # Layout structs: NavItem, PageData
      layout = vc::LAYOUT
      layout[:structs].each { |name, fields| structs << vc.go_struct(name, fields) }
      structs << vc.go_struct(:page_data, layout[:fields])

      # Form structs: FormOption, FormField, FormData
      form = vc::FORM
      form[:structs].each { |name, fields| structs << vc.go_struct(name, fields) }
      structs << vc.go_struct(:form_data, form[:fields])

      # RowAction (from index contract)
      index = vc::INDEX
      structs << vc.go_struct(:row_action, index[:structs][:row_action])

      struct_lines = structs.map { |s| s.sub("template.HTML", "template.HTML") }

      <<~GO
        package server

        import (
        \t"bytes"
        \t"html/template"
        \t"net/http"
        \t"path/filepath"
        )

        #{struct_lines.join("\n\n")}

        type Renderer struct {
        \tviewsDir string
        \tnav      []NavItem
        \tbrand    string
        }

        func NewRenderer(viewsDir string, brand string, nav []NavItem) *Renderer {
        \treturn &Renderer{viewsDir: viewsDir, nav: nav, brand: brand}
        }

        func (r *Renderer) Render(w http.ResponseWriter, templateName string, title string, data interface{}) {
        \tcontentTmpl, err := template.ParseFiles(filepath.Join(r.viewsDir, templateName+".html"))
        \tif err != nil {
        \t\thttp.Error(w, "Template error: "+err.Error(), 500)
        \t\treturn
        \t}
        \tvar contentBuf bytes.Buffer
        \tif err := contentTmpl.ExecuteTemplate(&contentBuf, templateName, data); err != nil {
        \t\thttp.Error(w, "Render error: "+err.Error(), 500)
        \t\treturn
        \t}
        \tlayoutTmpl, err := template.ParseFiles(filepath.Join(r.viewsDir, "layout.html"))
        \tif err != nil {
        \t\thttp.Error(w, "Layout error: "+err.Error(), 500)
        \t\treturn
        \t}
        \tpage := PageData{
        \t\tTitle:    title,
        \t\tBrand:    r.brand,
        \t\tNavItems: r.nav,
        \t\tContent:  template.HTML(contentBuf.String()),
        \t}
        \tw.Header().Set("Content-Type", "text/html; charset=utf-8")
        \tlayoutTmpl.ExecuteTemplate(w, "layout", page)
        }
      GO
    end
  end
end
