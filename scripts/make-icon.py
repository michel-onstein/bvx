#!/usr/bin/env python3
"""Generate the bvx app-icon artwork: a beaded strand plus a corner X.

    ./scripts/make-icon.py Resources            # write bvx-icon.svg
    ./scripts/make-icon.py /tmp/out --variants  # write every colour variant

Geometry follows Apple's macOS icon grid: a 1024x1024 canvas with the icon
body inset 100pt on every side and a 185.4pt corner radius. Anything drawn
outside that body is shadow only, so the artwork survives the squircle mask
macOS applies in the Dock.

The strand is one quadratic Bezier; bead centres are sampled at equal
arc-length steps along it, so the spacing stays even as the curve flattens.
"""
import math
import pathlib
import sys

CANVAS = 1024.0
INSET = 100.0
BODY = CANVAS - 2 * INSET  # 824
RADIUS = 0.225 * BODY  # 185.4

# The strand: starts steep in the upper left, flattens as it runs down to the
# right so it aims into the X rather than lifting away from it.
P0, P1, P2 = (244.0, 278.0), (390.0, 448.0), (676.0, 494.0)

X_CENTRE = (774.0, 752.0)
X_ARM = 63.0
X_WEIGHT = 55.0

BEAD_COUNT = 4
BEAD_RADIUS = 68.0

DEFAULT_VARIANT = "graphite"

PALETTES = {
    "graphite": dict(
        bg1="#2C3752", bgmid="#1B2233", bg2="#0C1017",
        accent="#2FD2AC", accent2="#17A184",
        strand="#A8BBDD", strand_opacity=0.52, sheen=0.09,
    ),
    "teal": dict(
        bg1="#157563", bgmid="#0C483E", bg2="#052722",
        accent="#FFFFFF", accent2="#CFEFE6",
        strand="#FFFFFF", strand_opacity=0.45, sheen=0.11,
    ),
    "indigo": dict(
        bg1="#4B3792", bgmid="#2C2058", bg2="#130E29",
        accent="#FFB53D", accent2="#E4901A",
        strand="#C9BDF2", strand_opacity=0.48, sheen=0.10,
    ),
}


def _point(t):
    u = 1.0 - t
    return (u * u * P0[0] + 2 * u * t * P1[0] + t * t * P2[0],
            u * u * P0[1] + 2 * u * t * P1[1] + t * t * P2[1])


def bead_centres(count, samples=2000):
    """`count` centres spaced evenly by arc length, from t=0 through t=1."""
    points = [_point(i / samples) for i in range(samples + 1)]
    lengths = [0.0]
    for i in range(1, len(points)):
        lengths.append(lengths[-1] + math.dist(points[i - 1], points[i]))
    total = lengths[-1]
    centres = []
    for k in range(count):
        target = total * k / (count - 1)
        i = min(range(len(lengths)), key=lambda j: abs(lengths[j] - target))
        centres.append(points[i])
    return centres


def icon_svg(variant=DEFAULT_VARIANT, bead_count=BEAD_COUNT, bead_radius=BEAD_RADIUS):
    palette = PALETTES[variant]
    body = f'x="{INSET}" y="{INSET}" width="{BODY}" height="{BODY}" rx="{RADIUS}" ry="{RADIUS}"'
    out = []
    add = out.append

    add('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024" role="img" aria-label="bvx">')
    add('<defs>')
    add('<linearGradient id="bg" x1="0.05" y1="0" x2="0.95" y2="1">'
        f'<stop offset="0" stop-color="{palette["bg1"]}"/>'
        f'<stop offset="0.5" stop-color="{palette["bgmid"]}"/>'
        f'<stop offset="1" stop-color="{palette["bg2"]}"/></linearGradient>')
    add('<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="{palette["sheen"]}"/>'
        '<stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>')
    add('<linearGradient id="bead" x1="0.2" y1="0" x2="0.75" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF"/>'
        '<stop offset="0.55" stop-color="#F4F7FC"/>'
        '<stop offset="1" stop-color="#CBD4E4"/></linearGradient>')
    add('<linearGradient id="xmark" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="{palette["accent"]}"/>'
        f'<stop offset="1" stop-color="{palette["accent2"]}"/></linearGradient>')
    add('<filter id="cast" x="-30%" y="-30%" width="160%" height="170%">'
        '<feDropShadow dx="0" dy="18" stdDeviation="20" flood-color="#000000" '
        'flood-opacity="0.38"/></filter>')
    add('<filter id="lift" x="-40%" y="-40%" width="180%" height="180%">'
        '<feDropShadow dx="0" dy="9" stdDeviation="11" flood-color="#000814" '
        'flood-opacity="0.45"/></filter>')
    add(f'<clipPath id="clip"><rect {body}/></clipPath>')
    add('</defs>')

    add(f'<rect {body} fill="url(#bg)" filter="url(#cast)"/>')
    add(f'<g clip-path="url(#clip)"><rect {body} fill="url(#sheen)"/></g>')

    add('<g filter="url(#lift)">')
    add(f'<path d="M {P0[0]} {P0[1]} Q {P1[0]} {P1[1]} {P2[0]} {P2[1]}" fill="none" '
        f'stroke="{palette["strand"]}" stroke-opacity="{palette["strand_opacity"]}" '
        f'stroke-width="{bead_radius * 0.30:.1f}" stroke-linecap="round"/>')
    for cx, cy in bead_centres(bead_count):
        add(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{bead_radius}" fill="url(#bead)"/>')
        add(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{bead_radius - 1.5}" fill="none" '
            'stroke="#FFFFFF" stroke-opacity="0.65" stroke-width="3"/>')
        hx, hy = cx - bead_radius * 0.30, cy - bead_radius * 0.34
        add(f'<ellipse cx="{hx:.1f}" cy="{hy:.1f}" rx="{bead_radius * 0.34:.1f}" '
            f'ry="{bead_radius * 0.23:.1f}" fill="#FFFFFF" fill-opacity="0.9" '
            f'transform="rotate(-38 {hx:.1f} {hy:.1f})"/>')
    add('</g>')

    cx, cy = X_CENTRE
    add(f'<g filter="url(#lift)" stroke="url(#xmark)" stroke-width="{X_WEIGHT}" '
        'stroke-linecap="round">')
    add(f'<line x1="{cx - X_ARM}" y1="{cy - X_ARM}" x2="{cx + X_ARM}" y2="{cy + X_ARM}"/>')
    add(f'<line x1="{cx - X_ARM}" y1="{cy + X_ARM}" x2="{cx + X_ARM}" y2="{cy - X_ARM}"/>')
    add('</g>')

    add(f'<rect x="{INSET + 1}" y="{INSET + 1}" width="{BODY - 2}" height="{BODY - 2}" '
        f'rx="{RADIUS - 1}" ry="{RADIUS - 1}" fill="none" stroke="#FFFFFF" '
        'stroke-opacity="0.14" stroke-width="2"/>')
    add('</svg>')
    return "\n".join(out) + "\n"


def main(argv):
    out_dir = pathlib.Path(argv[1] if len(argv) > 1 else "Resources")
    every = "--variants" in argv
    out_dir.mkdir(parents=True, exist_ok=True)
    if every:
        for variant in PALETTES:
            for count, radius in ((4, 68.0), (5, 57.0)):
                path = out_dir / f"{variant}-{count}bead.svg"
                path.write_text(icon_svg(variant, count, radius))
                print(path)
    else:
        path = out_dir / "bvx-icon.svg"
        path.write_text(icon_svg())
        print(path)


if __name__ == "__main__":
    main(sys.argv)
