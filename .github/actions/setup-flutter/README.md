# Pinned Flutter setup action

This is the existing MIT-licensed `subosito/flutter-action` from
[commit 1a449444c387b1966244ae4d4f8c696479add0b2](https://github.com/subosito/flutter-action/tree/1a449444c387b1966244ae4d4f8c696479add0b2).
Its `setup.sh` and `LICENSE` are retained verbatim. The only changes to
`action.yaml` replace its two `actions/cache@v5` references with the complete
[actions/cache commit caa296126883cff596d87d8935842f9db880ef25](https://github.com/actions/cache/commit/caa296126883cff596d87d8935842f9db880ef25).
The GitHub API confirmed that `v5` resolved to this commit when vendored.

The repository requires full SHA pins for all Actions, including nested
composite steps. Pinning only the upstream Flutter action was insufficient:
GitHub rejected its floating cache references before tests or packaging began.
Using this checked-in copy keeps that requirement enabled without changing
Flutter 3.47.1, the SDK/pub cache keys, installation script or workflow inputs.
Both callers check out the repository before invoking the local action.

`provenance.json` records the upstream revision, original file SHA-256 values
and the reviewed cache pin. `tools/test_release_workflow_security.py` verifies
those hashes, the narrowly modified manifest and full pins in workflows and
local composite actions. An upstream update must refresh these records and
retain its license; do not copy a floating cache reference back into this file.
