"""Arma los archivos que se publican en el hosting (lflhardcase.com.py).

dist/site/     -> public_html/          (web de LFL: index.html + fotos)
dist/gestion/  -> public_html/gestion/  (sistema.html renombrado a "LFL Gestión")

Si algún texto de marca ya no aparece en sistema.html, el script falla a propósito
para no publicar una versión a medio renombrar. En ese caso hay que actualizar REPLACEMENTS.
"""
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
SITE = DIST / "site"
GESTION = DIST / "gestion"

SITE_FILES = ["index.html"] + sorted(p.name for p in ROOT.glob("0[1-9]_*.png"))
GESTION_EXTRA = ["plantilla_catalogo_LFL.xlsx"]

REPLACEMENTS = [
    (
        "<title>LFL Hardcase · Presupuestos</title>",
        "<title>LFL Gestión</title>\n"
        '<link rel="icon" href="logo.svg" type="image/svg+xml">\n'
        '<link rel="apple-touch-icon" href="icon-180.png">\n'
        '<link rel="manifest" href="manifest.webmanifest">\n'
        '<meta name="theme-color" content="#1A1A1A">\n'
        '<meta name="apple-mobile-web-app-title" content="LFL Gestión">\n'
        '<meta name="apple-mobile-web-app-capable" content="yes">',
    ),
    (
        ".brand-mark{width:36px;height:36px;border-radius:7px;background:linear-gradient(145deg,#2a2d31,#0e0f11);border:2px solid #8f8a82;position:relative;flex:none}",
        ".brand-mark{width:38px;height:38px;border-radius:9px;background:url(logo.svg) center/cover no-repeat;box-shadow:0 0 0 1px rgba(255,255,255,.14);position:relative;flex:none}",
    ),
    (
        '.brand-mark:before,.brand-mark:after{content:"";position:absolute;width:7px;height:7px;border-radius:50%;background:#b9b3a9;top:-4px}',
        ".brand-mark:before,.brand-mark:after{display:none}",
    ),
    (
        ".brand-mark i{position:absolute;left:8px;right:8px;top:14px;height:4px;border-radius:2px;background:var(--accent)}",
        ".brand-mark i{display:none}",
    ),
    (
        "<b>LFL HARDCASE</b><small>Presupuestos</small>",
        '<b>LFL <span style="color:#E63946">GESTIÓN</span></b><small>Hard Case</small>',
    ),
    (
        '<h2>LFL Hardcase</h2><div class="small muted">Sistema de presupuestos</div>',
        '<h2>LFL Gestión</h2><div class="small muted">Presupuestos y facturación</div>',
    ),
]


def main() -> int:
    if DIST.exists():
        shutil.rmtree(DIST)
    SITE.mkdir(parents=True)
    GESTION.mkdir(parents=True)

    for name in SITE_FILES:
        shutil.copy2(ROOT / name, SITE / name)

    html = (ROOT / "sistema.html").read_text(encoding="utf-8")
    missing = []
    for old, new in REPLACEMENTS:
        count = html.count(old)
        if count != 1:
            missing.append(f"  - aparece {count} veces (se esperaba 1): {old[:70]}")
            continue
        html = html.replace(old, new)
    if missing:
        print("ERROR: sistema.html cambió y no se pudo aplicar la marca LFL Gestión:")
        print("\n".join(missing))
        print("Actualizá REPLACEMENTS en scripts/build_hosting.py.")
        return 1
    (GESTION / "index.html").write_text(html, encoding="utf-8")

    for f in (ROOT / "branding" / "gestion").iterdir():
        shutil.copy2(f, GESTION / f.name)
    for name in GESTION_EXTRA:
        if (ROOT / name).exists():
            shutil.copy2(ROOT / name, GESTION / name)

    for d in (SITE, GESTION):
        print(f"{d.relative_to(ROOT)}: " + ", ".join(sorted(p.name for p in d.iterdir())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
