#!/usr/bin/env python3
"""Arma AeroGrid-Demo-Opus.html autocontenido (JS + íconos en base64) a partir de src/."""
from pathlib import Path
import base64, json
ROOT = Path(__file__).resolve().parent
icons = {p.stem: 'data:image/png;base64,' + base64.b64encode(p.read_bytes()).decode() for p in sorted((ROOT / 'assets/icons').glob('*.png'))}
html = (ROOT / 'src/template.html').read_text()
html = html.replace('/*ICONS*/{}', json.dumps(icons)).replace('/*DEMO_JS*/', (ROOT / 'src/demo.js').read_text())
out = ROOT / 'AeroGrid-Demo-Opus.html'
out.write_text(html)
print(out, len(html))
