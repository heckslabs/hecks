require_relative "ui_generator/form_routes"
require_relative "ui_generator/config_routes"
require_relative "ui_generator/show_route"

module HecksStatic
# HecksStatic::UIGenerator
#
# Generates route handlers that prepare data and render ERB templates.
# Each route builds a locals hash and calls renderer.render(:template, locals).
#
class UIGenerator < Hecks::Generator
  include FormRoutes
  include ConfigRoutes
  include ShowRoute

  def initialize(domain)
    @domain = domain
  end

  def generate(mod, gem_name)
    lines = []
    lines << "require \"erb\""
    lines << "require_relative \"renderer\""
    lines << ""
    lines << "module #{mod}"
    lines << "  module Server"
    lines << "    module UIRoutes"
    lines << ""
    lines << "      def mount_ui_routes(server)"
    lines << "        views = File.expand_path(\"views\", __dir__)"
    lines << "        renderer = Renderer.new(views)"
    lines << "        nav = #{nav_items.inspect}"
    lines << "        brand = \"#{mod}\""
    lines << ""
    lines.concat(root_route(mod))
    @domain.aggregates.each { |agg| lines.concat(index_route(agg, mod)) }
    @domain.aggregates.each { |agg| lines.concat(show_route(agg, mod)) }
    @domain.aggregates.each { |agg| lines.concat(new_routes(agg, mod)) }
    lines.concat(config_route(mod))
    lines.concat(reboot_route(mod))
    lines << "      end"
    lines << ""
    lines.concat(csrf_helpers)
    lines << "    end"
    lines << "  end"
    lines << "end"
    lines.join("\n") + "\n"
  end

  private

  def nav_items
    items = [{ label: "Home", href: "/" }]
    @domain.aggregates.each do |agg|
      items << { label: HecksTemplating::UILabelContract.plural_label(agg.name), href: "/#{plural(agg)}" }
    end
    items << { label: "Config", href: "/config" }
    items
  end

  def plural(agg)
    domain_aggregate_slug(agg.name)
  end

  def user_attrs(agg)
    agg.attributes.reject { |a|
      Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) || !a.visible?
    }
  end

  def self_ref?(cmd, agg_snake)
    suffixes = agg_snake.split("_").each_index.map { |i|
      agg_snake.split("_").drop(i).join("_")
    }.uniq
    cmd.attributes.any? { |a|
      a.name.to_s.end_with?("_id") &&
        suffixes.any? { |s| a.name.to_s == "#{s}_id" }
    }
  end

  def find_self_ref_attr(cmd, agg)
    agg_snake = domain_snake_name(agg.name)
    suffixes = agg_snake.split("_").each_index.map { |i|
      agg_snake.split("_").drop(i).join("_")
    }.uniq
    cmd.attributes.find { |a|
      a.name.to_s.end_with?("_id") &&
        suffixes.any? { |s| a.name.to_s == "#{s}_id" }
    }
  end

  def required_field?(agg, attr_name)
    return true if agg.validations.any? { |v| v.field.to_s == attr_name.to_s && v.rules[:presence] }
    agg.value_objects.any? { |vo| vo.attributes.any? { |va| va.name.to_s == attr_name.to_s } }
  end

  def humanize(name)
    name.to_s.split("_").map(&:capitalize).join(" ")
  end

  def csrf_helpers
    [
      "      private",
      "",
      "      def ensure_csrf_cookie(req, res)",
      "        existing = read_csrf_cookie(req)",
      "        return existing if existing && !existing.empty?",
      "        require \"securerandom\"",
      "        token = SecureRandom.hex(32)",
      "        res[\"Set-Cookie\"] = \"_csrf_token=\#{token}; SameSite=Strict; HttpOnly\"",
      "        token",
      "      end",
      "",
      "      def read_csrf_cookie(req)",
      "        header = req[\"Cookie\"] || \"\"",
      "        m = header.match(/(?:^|;\\s*)_csrf_token=([^;]+)/)",
      "        m ? m[1] : nil",
      "      end",
      "",
      "      def validate_csrf(req)",
      "        cookie = read_csrf_cookie(req)",
      "        form  = req.query[\"_csrf_token\"]",
      "        cookie && !cookie.empty? && cookie == form",
      "      end",
    ]
  end

  def root_route(mod)
    agg_data = @domain.aggregates.map do |agg|
      d = HecksTemplating::DisplayContract.home_aggregate_data(agg, plural(agg))
      "{ name: \"#{d[:name]}\", href: \"#{d[:href]}\", command_names: \"#{d[:command_names]}\", attributes: #{d[:attributes]}, policies: #{d[:policies]} }"
    end
    [
      "        server.mount_proc \"/\" do |req, res|",
      "          next unless req.path == \"/\"",
      "          html = renderer.render(:home, title: \"#{mod}\", brand: brand, nav_items: nav,",
      "            domain_name: \"#{mod}\", aggregates: [#{agg_data.join(', ')}])",
      "          res[\"Content-Type\"] = \"text/html\"; res.body = html",
      "        end",
      ""
    ]
  end

  def index_route(agg, mod)
    safe = domain_constant_name(agg.name)
    p = plural(agg)
    attrs = user_attrs(agg)
    agg_snake = domain_snake_name(agg.name)
    ac = HecksTemplating::AggregateContract
    dc = HecksTemplating::DisplayContract
    create_cmds, update_cmds = ac.partition_commands(agg)

    columns = attrs.map { |a|
      lbl = dc.reference_attr?(a) ? dc.reference_column_label(a) : humanize(a.name)
      "{ label: \"#{lbl}\" }"
    }
    btns = create_cmds.map { |c| cm = domain_snake_name(c.name); "{ label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", href: \"/#{p}/#{cm}/new\", allowed: #{mod}.role_allows?(\"#{safe}\", \"#{cm}\") }" }
    row_acts = update_cmds.map do |c|
      cm = domain_snake_name(c.name)
      if ac.direct_action?(c, agg_snake)
        self_id = ac.self_ref_attr(c, agg_snake)
        "{ label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", href_prefix: \"/#{p}/#{cm}/submit\", allowed: #{mod}.role_allows?(\"#{safe}\", \"#{cm}\"), direct: true, id_field: \"#{self_id&.name}\" }"
      else
        "{ label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", href_prefix: \"/#{p}/#{cm}/new?id=\", allowed: #{mod}.role_allows?(\"#{safe}\", \"#{cm}\") }"
      end
    end

    cell_exprs = attrs.map { |a| dc.cell_expression(a, "obj", lang: :ruby, domain: @domain) }
    cells_code = cell_exprs.map { |e| e }.join(", ")

    [
      "        server.mount_proc \"/#{p}\" do |req, res|",
      "          next unless req.path == \"/#{p}\"",
      "          all_items = #{safe}.all",
      "          items = all_items.map { |obj| { id: obj.id, short_id: #{HecksTemplating::ViewContract.ruby_short_id('obj.id')}, show_href: \"/#{p}/show?id=\" + obj.id, cells: [#{cells_code}] } }",
      "          html = renderer.render(:index, title: \"#{safe}s — #{mod}\", brand: brand, nav_items: nav,",
      "            aggregate_name: \"#{safe}\", items: items,",
      "            csrf_token: ensure_csrf_cookie(req, res),",
      "            columns: [#{columns.join(', ')}],",
      "            buttons: [#{btns.join(', ')}],",
      "            row_actions: [#{row_acts.join(', ')}])",
      "          res[\"Content-Type\"] = \"text/html\"; res.body = html",
      "        end",
      ""
    ]
  end

end
end
