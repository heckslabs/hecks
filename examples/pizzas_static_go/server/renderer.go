package server

import (
	"bytes"
	"html/template"
	"net/http"
	"path/filepath"
)

type NavItem struct { Label string; Href string; Group string }

type PageData struct { Title string; Brand string; Content template.HTML; NavItems []NavItem }

type FormField struct { Type string; Name string; Label string; InputType string; Value string; Required bool; Step bool; Error string; Options []FormOption }

type FormOption struct { Value string; Label string; Selected bool }

type FormData struct { CommandName string; Action string; ErrorMessage string; CsrfToken string; Fields []FormField }

type RowAction struct { Label string; HrefPrefix string; Id string; Allowed bool; Direct bool; IdField string }

type Renderer struct {
	viewsDir string
	nav      []NavItem
	brand    string
}

func NewRenderer(viewsDir string, brand string, nav []NavItem) *Renderer {
	return &Renderer{viewsDir: viewsDir, nav: nav, brand: brand}
}

func (r *Renderer) Render(w http.ResponseWriter, templateName string, title string, data interface{}) {
	contentTmpl, err := template.ParseFiles(filepath.Join(r.viewsDir, templateName+".html"))
	if err != nil {
		http.Error(w, "Template error: "+err.Error(), 500)
		return
	}
	var contentBuf bytes.Buffer
	if err := contentTmpl.ExecuteTemplate(&contentBuf, templateName, data); err != nil {
		http.Error(w, "Render error: "+err.Error(), 500)
		return
	}
	layoutTmpl, err := template.ParseFiles(filepath.Join(r.viewsDir, "layout.html"))
	if err != nil {
		http.Error(w, "Layout error: "+err.Error(), 500)
		return
	}
	page := PageData{
		Title:    title,
		Brand:    r.brand,
		NavItems: r.nav,
		Content:  template.HTML(contentBuf.String()),
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	layoutTmpl.ExecuteTemplate(w, "layout", page)
}
