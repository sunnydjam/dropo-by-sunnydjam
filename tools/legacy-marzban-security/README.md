# Legacy Marzban security compatibility build

Preserves the existing Marzban 0.8.4 API/schema and legacy subscription contract.
Upstream source: <https://github.com/Gozargah/Marzban/tree/v0.8.4> (AGPL-3.0).
The previously deployed image is pinned by its complete immutable digest in
the Dockerfile; its `/code` tree is the upstream application source.

Changes: Python 3.12.16 and 69 locked distributions, in-memory Reality X25519
derivation compatible with modern Xray output, and a startup path guard that
handles lazy FastAPI routers. No migration removes users or rotates their keys.
The database, JWT secret, original subscription paths, UUIDs and expiry policy
remain existing state. Do not include those private files in a source offer.

`requirements.lock` pins the exact Linux x86-64 / Python 3.12 distributions,
including four source distributions. Every hash was independently matched to
the corresponding file in the official PyPI version metadata. The wheel stage
has a separately hash-locked pip/setuptools bootstrap and disables isolated,
unlocked build dependency installation. `environment.json` records the tested
candidate environment, not a promise of identical Docker image IDs on rebuild.

Build in an isolated directory/container with no production configuration:

```sh
docker build -t dropo-marzban:security-local .
```

Re-run the full dependency scan and `canary_legacy_image.py` against its actual
image ID before promotion. A successful image build alone is not acceptance.
The production host retains an existing custom core wrapper: apply the small
X25519 adapter to that reviewed wrapper and mount it read-only, retaining the
pre-existing local modifications. Production compose also pins the verified
Xray runtime read-only and limits capabilities, memory and CPU.

`deployed_core.py` is the complete deployed wrapper, SHA256
`20f0389522405be2a9fdd6db08367f49cf277978f1685bbebf187bf8f7e0904f`.
It was checked for embedded secrets before inclusion. The Dockerfile installs
that complete corresponding source, including the existing local changes and
the small X25519 adapter; no production state is part of this source tree.

The standalone compatibility edits retain AGPL-3.0-only notices. Provide this
recipe, locks and patches alongside the corresponding upstream source to users
of the modified web service; deployment secrets are not corresponding source.
The deployment audit/restore evidence belongs outside public source bundles.
