# SVG

Beacon provides SVG element and attribute helpers for rendering inline vector graphics in views. The `svg` root element automatically includes the SVG namespace (`xmlns`), so elements render correctly in the browser.

Import with `import beacon/svg`.

## Element Functions

### Container elements

| Function | HTML element | Takes children |
|----------|-------------|----------------|
| `svg` | `<svg>` | yes |
| `g` | `<g>` | yes |
| `defs` | `<defs>` | yes |
| `symbol` | `<symbol>` | yes |
| `use_` | `<use>` | no |
| `clip_path` | `<clipPath>` | yes |
| `mask` | `<mask>` | yes |

### Shape elements

| Function | HTML element |
|----------|-------------|
| `path` | `<path>` |
| `circle` | `<circle>` |
| `rect` | `<rect>` |
| `ellipse` | `<ellipse>` |
| `line` | `<line>` |
| `polyline` | `<polyline>` |
| `polygon` | `<polygon>` |

### Text, gradient, filter, animation, and other elements

| Function | HTML element | Takes children |
|----------|-------------|----------------|
| `text` | `<text>` | yes |
| `tspan` | `<tspan>` | yes |
| `linear_gradient` | `<linearGradient>` | yes |
| `radial_gradient` | `<radialGradient>` | yes |
| `stop` | `<stop>` | no |
| `filter` | `<filter>` | yes |
| `animate` | `<animate>` | no |
| `animate_transform` | `<animateTransform>` | no |
| `foreign_object` | `<foreignObject>` | yes |
| `image` | `<image>` | no |
| `title` | `<title>` | yes |
| `desc` | `<desc>` | yes |

## Attribute Functions

| Function | SVG attribute |
|----------|--------------|
| `viewbox` | `viewBox` |
| `d` | `d` |
| `fill` | `fill` |
| `stroke` | `stroke` |
| `stroke_width` | `stroke-width` |
| `stroke_linecap` | `stroke-linecap` |
| `stroke_linejoin` | `stroke-linejoin` |
| `stroke_dasharray` | `stroke-dasharray` |
| `stroke_dashoffset` | `stroke-dashoffset` |
| `cx`, `cy` | `cx`, `cy` |
| `r`, `rx`, `ry` | `r`, `rx`, `ry` |
| `x`, `y` | `x`, `y` |
| `x1`, `y1`, `x2`, `y2` | `x1`, `y1`, `x2`, `y2` |
| `width`, `height` | `width`, `height` |
| `points` | `points` |
| `transform` | `transform` |
| `opacity` | `opacity` |
| `fill_opacity` | `fill-opacity` |
| `stroke_opacity` | `stroke-opacity` |
| `fill_rule` | `fill-rule` |
| `clip_rule` | `clip-rule` |
| `attribute` | any (generic escape hatch) |

## Example

Render a simple triangle icon:

```gleam
import beacon/html
import beacon/svg

fn icon_triangle() {
  svg.svg([html.class("w-6 h-6"), svg.viewbox("0 0 24 24")], [
    svg.path([
      svg.d("M12 2L22 22H2Z"),
      svg.fill("none"),
      svg.stroke("currentColor"),
      svg.stroke_width("2"),
      svg.stroke_linejoin("round"),
    ]),
  ])
}
```

Use `svg.attribute(name, value)` for any SVG attribute not covered by the built-in helpers.
