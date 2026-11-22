# SPDX-License-Identifier: AGPL-3.0-only
"""Exact, fail-closed compatibility edit for Marzban 0.8.4 / modern FastAPI."""

def apply(source):
    old = '    paths = [f"{r.path}/" for r in app.routes]'
    new = '''    # Included routers can be lazy in modern FastAPI. The generated schema
    # supplies their resolved paths; keep concrete non-schema routes as well.
    paths = [f"{path}/" for path in app.openapi().get("paths", {})]
    paths.extend(f"{r.path}/" for r in app.routes if hasattr(r, "path"))'''
    if source.count(old) != 1:
        raise RuntimeError('Unexpected Marzban startup route guard')
    return source.replace(old, new)
