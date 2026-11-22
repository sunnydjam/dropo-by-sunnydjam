# SPDX-License-Identifier: AGPL-3.0-only
# Compatibility adapter for the existing Marzban XrayCore wrapper. Derive keys
# in memory: no production private key is placed in a subprocess command line.
_DROPO_SAFE_X25519_PATCH_V1 = True

def _dropo_x25519_pair(private_key=None):
    import base64
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    if private_key is None:
        key = X25519PrivateKey.generate()
    else:
        try:
            encoded = private_key.encode('ascii')
            if len(encoded) not in (43, 44):
                raise ValueError()
            raw = base64.b64decode(encoded + b'=' * (-len(encoded) % 4), altchars=b'-_', validate=True)
            if len(raw) != 32:
                raise ValueError()
            key = X25519PrivateKey.from_private_bytes(raw)
        except (ValueError, TypeError, AttributeError, UnicodeError):
            raise ValueError('Invalid Reality X25519 key') from None
    raw = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return {'private_key': base64.urlsafe_b64encode(raw).decode().rstrip('='),
            'public_key': base64.urlsafe_b64encode(public).decode().rstrip('=')}

XRayCore.get_x25519 = staticmethod(_dropo_x25519_pair)
