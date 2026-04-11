# Nursery Web Applications

Generate a domain-driven web app from Bluebook definitions in the nursery.

## Structure

```
nursery/<business>/apps/web/
  index.html          # App shell with sidebar navigation
  styles.css          # Master stylesheet (imports css/ modules)
  app.js              # Entry point
  css/                # Modular CSS: variables, base, layout, components
  js/                 # Modules: data (fixtures), brand-switcher, navigation
  pages/              # One page per bounded context group
```

## Domain Tags

Every HTML element maps to a domain concept:

```html
<tr data-domain-aggregate="Product">
  <td data-domain-attribute="sku"><code>DL-5W30-1QT</code></td>
  <td data-domain-attribute="name">DuraLube Engine Treatment</td>
</tr>
<button data-domain-command="PlaceOrder">Place Order</button>
```

## Brand Switcher

```html
<html data-brand="duralube">
```

CSS custom properties switch accent colors per brand. JS toggles
`data-brand` on `<html>` and filters product listings.

## Example: Alan's Engine Additive Business

16 bounded contexts, 9 pages, 491 domain-tagged elements:

```
ruby -Ilib -e "require 'hecks'; Hecks.boot('nursery/alans_engine_additive_business')"
open nursery/alans_engine_additive_business/apps/web/index.html
```
