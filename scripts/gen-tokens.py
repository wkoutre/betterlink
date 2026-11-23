#!/usr/bin/env python3
"""Generates Sources/Betterlink/DesignTokens.swift from Design/tokens.json.

Design/tokens.json is betterlink's design system, the same file as the
"betterlink" Design System artifact. Edit the tokens there, then run
`make tokens`. `make test` runs this with --check and fails when the Swift
file is out of date.
"""
import json, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Design/tokens.json"
OUT = ROOT / "Sources/Betterlink/DesignTokens.swift"

def ident(name):
    parts = re.split(r"[-_.]", name)
    s = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    return s if not s[0].isdigit() else "_" + s

def hexval(v):
    v = v.lstrip("#")
    if len(v) == 3: v = "".join(c * 2 for c in v)
    return "0x" + v[:6].upper()

def px(v):
    return float(str(v).replace("px", ""))

def shadow_layers(css):
    # "0 1px 2px rgba(20,28,51,0.05), 0 6px 20px rgba(...)" -> [(x, y, blur, r, g, b, a)]
    layers = []
    for part in re.split(r",(?![^(]*\))", css):
        m = re.match(r"\s*(-?[\d.]+)(?:px)?\s+(-?[\d.]+)(?:px)?\s+([\d.]+)(?:px)?\s+rgba\(([^)]*)\)", part)
        if not m:
            sys.exit(f"gen-tokens: can't read shadow layer {part!r}")
        r, g, b, a = [float(x) for x in m.group(4).split(",")]
        layers.append((float(m.group(1)), float(m.group(2)), float(m.group(3)), r / 255, g / 255, b / 255, a))
    return layers

def generate(t):
    themes = [th["id"] for th in t["color"]["themes"]]
    assert themes[:2] == ["light", "dark"], "expected light then dark themes"
    out = ["// Generated from Design/tokens.json by scripts/gen-tokens.py. Do not edit.",
           "// Change the tokens there and run `make tokens`.", "",
           "import AppKit", "import SwiftUI", "",
           "/// betterlink's design tokens. See Design/tokens.json for what each is for.",
           "enum DS {"]
    out.append("    enum Palette {")
    for tok in t["color"]["tokens"]:
        v = tok["value"]; l = v["light"] if isinstance(v, dict) else v; d = v.get("dark", l) if isinstance(v, dict) else v
        out.append(f"        /// {tok['usage']}")
        out.append(f"        static let {ident(tok['name'])} = dynamic(light: {hexval(l)}, dark: {hexval(d)})")
    out.append("    }")
    for fam, enum in (("spacing", "Space"), ("radius", "Radius"), ("size", "Size")):
        out.append(f"    enum {enum} {{")
        for tok in t.get(fam, {"tokens": []})["tokens"]:
            out.append(f"        /// {tok['usage']}")
            out.append(f"        static let {ident(tok['name'])}: CGFloat = {px(tok['value']):g}")
        out.append("    }")
    out.append("    enum TextStyle {")
    for g in t["type"]["groups"]:
        design = ".monospaced" if g["family"] == "mono" else ".default"
        for s in g["styles"]:
            w = {400: ".regular", 500: ".medium", 600: ".semibold", 700: ".bold"}[int(s["fontWeight"])]
            out.append(f"        /// {s.get('usage', '')}")
            out.append(f"        static let {ident(s['name'])} = Font.system(size: {px(s['fontSize']):g}, weight: {w}, design: {design})")
            if "letterSpacing" in s:
                out.append(f"        static let {ident(s['name'])}Tracking: CGFloat = {px(s['letterSpacing']):g}")
    out.append("    }")
    out.append("    enum Shadow {")
    for tok in t.get("shadow", {}).get("tokens", []):
        v = tok["value"]; l = v["light"] if isinstance(v, dict) else v; d = v.get("dark", l) if isinstance(v, dict) else v
        def arr(layers):
            return "[" + ", ".join(f"Layer(x: {x:g}, y: {y:g}, blur: {b:g}, red: {r:.4f}, green: {g_:.4f}, blue: {bl:.4f}, alpha: {a:g})"
                                   for x, y, b, r, g_, bl, a in layers) + "]"
        out.append(f"        /// {tok['usage']}")
        out.append(f"        static let {ident(tok['name'])} = (light: {arr(shadow_layers(l))}, dark: {arr(shadow_layers(d))})")
    out.append("        struct Layer { let x, y, blur, red, green, blue, alpha: CGFloat }")
    out.append("    }")
    out.append("}")
    out.append("")
    out.append("private func dynamic(light: UInt32, dark: UInt32) -> Color {")
    out.append("    func ns(_ v: UInt32) -> NSColor {")
    out.append("        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)")
    out.append("    }")
    out.append("    return Color(nsColor: NSColor(name: nil) { appearance in")
    out.append("        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light)")
    out.append("    })")
    out.append("}")
    return "\n".join(out) + "\n"

text = generate(json.loads(SRC.read_text()))
if "--check" in sys.argv:
    if not OUT.exists() or OUT.read_text() != text:
        sys.exit("gen-tokens: Sources/Betterlink/DesignTokens.swift is out of date; run `make tokens`")
else:
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)}")
