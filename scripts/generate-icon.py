#!/usr/bin/env python3
'''Preserve the supplied Codex cloud; reproduce its relief with editable SVG layers.'''
from pathlib import Path
from math import sqrt
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Assets/Brand/CodexProvided.svg'
svg = ET.fromstring(SOURCE.read_bytes())
assert svg.attrib['viewBox'] == '0 0 24 24'
paths = svg.findall('{http://www.w3.org/2000/svg}path')
assert len(paths) == 2
cloud = paths[1].attrib['d']
outline, cutouts = cloud.split('zm3.482 10.565', 1)
outline += 'z'
underline, chevron = cutouts.split('zM8.462 9.23', 1)
glyphs = 'M12.546 13.909' + underline + 'zM8.462 9.23' + chevron
# Continuous corner profile, based on the local native icon's silhouette.
# Keep its 824-point bounds and the supplied cloud/terminal coordinates.
tile = ('M12 0C15.88 0 17.84 0 19.4.52C21.46 1.21 22.79 2.55 23.48 4.6'
        'C24 6.16 24 8.12 24 12S24 17.84 23.48 19.4C22.79 21.46 21.46 22.79 19.4 23.48'
        'C17.84 24 15.88 24 12 24S6.16 24 4.6 23.48C2.54 22.79 1.21 21.46.52 19.4'
        'C0 17.84 0 15.88 0 12S0 6.16.52 4.6C1.21 2.54 2.54 1.21 4.6.52C6.16 0 8.12 0 12 0Z')
tile_side = 824
inset = (1024 - tile_side) / 2
scale = tile_side / 24
# A single filled silhouette joins the rim and tapered grip without an opacity
# seam. Keep the lens diameter and the original cloud/terminal placement.
lens_cx, lens_cy, lens_radius = 12, 11.9, 6.3
rim_width, grip_width = 1.10, 1.36
outer, inner = lens_radius + rim_width / 2, lens_radius - rim_width / 2
def grip_point(distance, offset):
    return f'{lens_cx + (distance - offset) / sqrt(2):.3f} {lens_cy + (distance + offset) / sqrt(2):.3f}'
lens_shape = (
    f'M{lens_cx + outer:.3f} {lens_cy:g}A{outer:g} {outer:g} 0 1 1 {lens_cx - outer:.3f} {lens_cy:g}'
    f'A{outer:g} {outer:g} 0 1 1 {lens_cx + outer:.3f} {lens_cy:g}Z'
    f'M{lens_cx + inner:.3f} {lens_cy:g}A{inner:g} {inner:g} 0 1 0 {lens_cx - inner:.3f} {lens_cy:g}'
    f'A{inner:g} {inner:g} 0 1 0 {lens_cx + inner:.3f} {lens_cy:g}Z'
    f'M{grip_point(6.14, -rim_width / 2)}'
    f'C{grip_point(6.75, -rim_width / 2)} {grip_point(6.90, -grip_width / 2)} {grip_point(7.25, -grip_width / 2)}'
    f'L{grip_point(11.40, -grip_width / 2)}'
    f'A{grip_width / 2:g} {grip_width / 2:g} 0 0 1 {grip_point(11.40, grip_width / 2)}'
    f'L{grip_point(7.25, grip_width / 2)}'
    f'C{grip_point(6.90, grip_width / 2)} {grip_point(6.75, rim_width / 2)} {grip_point(6.14, rim_width / 2)}Z'
)
for name in ['Light', 'Dark']:
    dark = name == 'Dark'
    tile_top, tile_bottom = ('#343536', '#111112') if dark else ('#FFFFFF', '#ECEDEF')
    edge_top, edge_bottom = ('#D0D1CE', '#6B6D70') if dark else ('#FFFFFF', '#C2C5CC')
    shadow = '.24' if dark else '.17'
    document = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
  <title id="title">Codex Lens</title>
  <desc id="desc">Nuage et terminal du SVG Codex fourni, reflets et bords inspirés de l’icône macOS, avec une loupe. Variante {name.lower()}.</desc>
  <defs>
    <linearGradient id="tile-fill" x1="0" y1="0" x2=".55" y2="1"><stop stop-color="{tile_top}"/><stop offset="1" stop-color="{tile_bottom}"/></linearGradient>
    <linearGradient id="tile-edge" x1="0" y1="0" x2=".8" y2="1"><stop stop-color="{edge_top}" stop-opacity=".68"/><stop offset=".3" stop-color="{edge_top}" stop-opacity=".10"/><stop offset=".72" stop-color="{edge_bottom}" stop-opacity=".08"/><stop offset="1" stop-color="{edge_bottom}" stop-opacity=".28"/></linearGradient>
    <radialGradient id="tile-light" cx=".1" cy="0" r="1"><stop stop-color="#FFFFFF" stop-opacity="{'.04' if dark else '.12'}"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>
    <linearGradient id="cloud-fill" gradientUnits="userSpaceOnUse" x1="12" y1="3" x2="12" y2="21"><stop stop-color="#B6AEFF"/><stop offset=".21" stop-color="#AC93FF"/><stop offset=".34" stop-color="#6B85FF"/><stop offset=".49" stop-color="#647FFF"/><stop offset=".78" stop-color="#3831FF"/><stop offset="1" stop-color="#342CFF"/></linearGradient>
    <radialGradient id="cloud-crown" gradientUnits="userSpaceOnUse" cx="10.2" cy="3.5" r="5.6"><stop stop-color="#DEE4FF" stop-opacity=".57"/><stop offset=".62" stop-color="#D0B7FF" stop-opacity=".12"/><stop offset="1" stop-color="#D0B7FF" stop-opacity="0"/></radialGradient>
    <radialGradient id="cloud-left" gradientUnits="userSpaceOnUse" cx="6.2" cy="11.3" r="5.1"><stop stop-color="#80B2FF" stop-opacity=".67"/><stop offset=".7" stop-color="#79AAFF" stop-opacity=".20"/><stop offset="1" stop-color="#79AAFF" stop-opacity="0"/></radialGradient>
    <radialGradient id="cloud-right" gradientUnits="userSpaceOnUse" cx="17.6" cy="7.1" r="5.1"><stop stop-color="#A8B5FF" stop-opacity=".55"/><stop offset="1" stop-color="#A8B5FF" stop-opacity="0"/></radialGradient>
    <radialGradient id="cloud-front" gradientUnits="userSpaceOnUse" cx="12.4" cy="13.2" r="8.2" gradientTransform="translate(0 5.28) scale(1 .6)"><stop stop-color="#85B4FF" stop-opacity=".70"/><stop offset=".65" stop-color="#6FA0FF" stop-opacity=".26"/><stop offset=".9" stop-color="#6FA0FF" stop-opacity="0"/></radialGradient>
    <radialGradient id="cloud-front-right" gradientUnits="userSpaceOnUse" cx="18.5" cy="15.4" r="4.4" gradientTransform="translate(0 3.388) scale(1 .78)"><stop stop-color="#8AB9FF" stop-opacity=".48"/><stop offset="1" stop-color="#8AB9FF" stop-opacity="0"/></radialGradient>
    <linearGradient id="cloud-edge" gradientUnits="userSpaceOnUse" x1="9" y1="3" x2="14" y2="21"><stop stop-color="#F3F4FF"/><stop offset=".25" stop-color="#98AEFF"/><stop offset=".57" stop-color="#5370FF"/><stop offset="1" stop-color="#A4D2FF"/></linearGradient>
    <linearGradient id="terminal-fill" gradientUnits="userSpaceOnUse" x1="12" y1="9" x2="12" y2="15.3"><stop stop-color="#F4F7FF"/><stop offset="1" stop-color="#D8E6FF"/></linearGradient>
    <linearGradient id="lens-fill" gradientUnits="userSpaceOnUse" x1="9" y1="5" x2="18" y2="20"><stop stop-color="#FFFFFF"/><stop offset="1" stop-color="#D9E7FF"/></linearGradient>
    <clipPath id="tile-clip"><path d="{tile}"/></clipPath>
    <clipPath id="cloud-clip"><path d="{cloud}"/></clipPath>
    <filter id="tile-bevel" x="-.1" y="-.1" width="1.2" height="1.2" color-interpolation-filters="sRGB">
      <feOffset in="SourceAlpha" dx=".12" dy=".22" result="inset"/>
      <feComposite in="SourceAlpha" in2="inset" operator="out" result="edge"/>
      <feGaussianBlur in="edge" stdDeviation=".09" result="soft-edge"/>
      <feFlood flood-color="#FFFFFF" flood-opacity="{'.45' if dark else '.7'}"/>
      <feComposite in2="soft-edge" operator="in"/>
    </filter>
    <filter id="cloud-shadow" x="-.2" y="-.2" width="1.4" height="1.5" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation=".22"/><feOffset dy=".18" result="shadow"/>
      <feFlood flood-color="#142050" flood-opacity="{shadow}"/><feComposite in2="shadow" operator="in"/>
    </filter>
    <filter id="cloud-inset" x="-.1" y="-.1" width="1.2" height="1.2" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation=".11" result="soft-alpha"/>
      <feComposite in="SourceAlpha" in2="soft-alpha" operator="out" result="inner-edge"/>
      <feFlood flood-color="#3032D8" flood-opacity=".65"/><feComposite in2="inner-edge" operator="in"/>
    </filter>
    <filter id="cloud-bevel" x="-.1" y="-.1" width="1.2" height="1.2" color-interpolation-filters="sRGB">
      <feOffset in="SourceAlpha" dy=".115" result="inset"/>
      <feComposite in="SourceAlpha" in2="inset" operator="out" result="edge"/>
      <feGaussianBlur in="edge" stdDeviation=".045" result="soft-edge"/>
      <feFlood flood-color="#F6F5FF" flood-opacity=".68"/><feComposite in2="soft-edge" operator="in"/>
    </filter>
    <filter id="lens-shadow" x="-.2" y="-.2" width="1.4" height="1.4" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation=".045"/><feOffset dy=".065" result="shadow"/>
      <feFlood flood-color="#22203F" flood-opacity=".23"/><feComposite in2="shadow" operator="in" result="ink"/>
      <feMerge><feMergeNode in="ink"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <g transform="translate({inset:g} {inset:g}) scale({scale:.9f})">
    <path id="codex-tile" d="{tile}" fill="url(#tile-fill)"/>
    <path d="{tile}" fill="url(#tile-light)"/>
    <g clip-path="url(#tile-clip)"><path d="{tile}" fill="#FFFFFF" filter="url(#tile-bevel)"/><path d="{tile}" fill="none" stroke="url(#tile-edge)" stroke-width=".08"/></g>
    <path d="{outline}" fill="#142050" filter="url(#cloud-shadow)"/>
    <path id="codex-cloud" d="{cloud}" fill="url(#cloud-fill)"/>
    <g clip-path="url(#cloud-clip)">
      <rect width="24" height="24" fill="url(#cloud-crown)"/>
      <rect width="24" height="24" fill="url(#cloud-left)"/>
      <rect width="24" height="24" fill="url(#cloud-right)"/>
      <rect width="24" height="24" fill="url(#cloud-front)"/>
      <rect width="24" height="24" fill="url(#cloud-front-right)"/>
      <path d="{outline}" fill="#3032D8" filter="url(#cloud-inset)"/>
      <path d="{outline}" fill="none" stroke="url(#cloud-edge)" stroke-width=".19"/>
      <path d="{outline}" fill="#FFFFFF" filter="url(#cloud-bevel)"/>
    </g>
    <path id="codex-terminal" d="{glyphs}" fill="url(#terminal-fill)" stroke="#FFFFFF" stroke-opacity=".85" stroke-width=".055"/>
    <path d="{glyphs}" fill="#FFFFFF" filter="url(#cloud-bevel)"/>
    <g id="lens" opacity=".98" filter="url(#lens-shadow)">
      <path d="{lens_shape}" fill="url(#lens-fill)" fill-rule="nonzero"/>
    </g>
  </g>
</svg>
'''
    target = ROOT / f'Assets/CodexLens-{name}.svg'
    target.write_text(document)
    generated = ET.fromstring(document)
    assert generated.find('.//*[@id="codex-cloud"]').attrib['d'] == cloud
    assert generated.find('.//*[@id="codex-terminal"]').attrib['d'] == glyphs
(ROOT / 'Assets/CodexLens.svg').write_bytes((ROOT / 'Assets/CodexLens-Dark.svg').read_bytes())
print(f'Original cloud/terminal paths preserved; {tile_side}px tile, {inset:g}px margins; vector relief layers.')
