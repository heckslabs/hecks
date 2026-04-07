# GoHecks::IndexTemplate
#
# Generates the Go html/template for the index page directly,
# without ERB conversion. Handles direct-action row buttons
# for commands with no user fields.
#
module GoHecks
  class IndexTemplate
    def generate
      <<~GO
        {{ define "index" }}
        <div class="header-row">
          <h1>{{ .AggregateName }}s ({{ len .Items }})</h1>
          <div>
            {{ range .Buttons }}
              <a class="btn{{ if not .Allowed }} btn-faded{{ end }}" href="{{ .Href }}">{{ .Label }}</a>
            {{ end }}
          </div>
        </div>
        {{ if .Description }}<p style="color:#666;margin:-1rem 0 1.5rem">{{ .Description }}</p>{{ end }}
        <table>
          <thead>
            <tr>
              <th>ID</th>
              {{ range .Columns }}<th>{{ .Label }}</th>{{ end }}
              {{ if .RowActions }}<th>Actions</th>{{ end }}
            </tr>
          </thead>
          <tbody>
            {{ range .Items }}
              <tr>
                <td class="mono"><a href="{{ .ShowHref }}">{{ .ShortId }}</a></td>
                {{ range .Cells }}<td>{{ . }}</td>{{ end }}
                {{ if .RowActions }}
                  <td>
                    {{ $csrf := $.CsrfToken }}
                    {{ range .RowActions }}
                      {{ if .Direct }}
                        <form class="inline" method="post" action="{{ .HrefPrefix }}">
                          <input type="hidden" name="_csrf_token" value="{{ $csrf }}">
                          <input type="hidden" name="{{ .IdField }}" value="{{ .Id }}">
                          <button class="btn btn-sm{{ if not .Allowed }} btn-faded{{ end }}" type="submit">{{ .Label }}</button>
                        </form>
                      {{ else }}
                        <a class="btn btn-sm{{ if not .Allowed }} btn-faded{{ end }}"
                           href="{{ .HrefPrefix }}{{ .Id }}">{{ .Label }}</a>
                      {{ end }}
                    {{ end }}
                  </td>
                {{ end }}
              </tr>
            {{ end }}
          </tbody>
        </table>
        {{ end }}
      GO
    end
  end
end
