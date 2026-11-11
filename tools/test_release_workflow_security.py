"""Evaluate the actual pre-checkout publishing condition against hostile events."""
import hashlib,json,re,unittest
from pathlib import Path

WORKFLOW=Path(__file__).resolve().parents[1]/'.github/workflows/release.yml'
ROOT=WORKFLOW.parents[2]

def action_references(text):
    return re.findall(r'^\s*(?:-\s*)?uses:\s*[\"\']?([^\s\"\'#]+)',text,re.M)

def require_action_pins(text):
    for reference in action_references(text):
        if reference.startswith('./'):
            continue
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}',reference):
            raise AssertionError('Action requires a complete commit SHA: '+reference)

def condition():
    text=WORKFLOW.read_text(encoding='utf-8')
    match=re.search(r'^    if: >-\n((?:      .+\n)+)',text,re.M)
    if not match:raise AssertionError('Publisher requires a job-level condition')
    clauses=[]
    for part in match[1].replace('\n',' ').split('&&'):
        m=re.fullmatch(r"\s*(github\.[\w.]+)\s*==\s*('([^']*)'|github\.[\w.]+)\s*",part)
        if not m:raise AssertionError('Unreviewed publishing expression: '+part)
        clauses.append((m[1],m[3] if m[2].startswith("'") else m[2],not m[2].startswith("'")))
    return text,clauses

def accepted(values):
    _,clauses=condition()
    return all(str(values.get(left,'')).casefold()==str(values.get(right,'') if variable else right).casefold() for left,right,variable in clauses)

class ReleaseTrust(unittest.TestCase):
    def setUp(self):
        self.event={'github.repository':'owner/project','github.event.workflow_run.head_repository.full_name':'owner/project','github.event.workflow_run.event':'push','github.event.workflow_run.conclusion':'success','github.event.workflow_run.head_branch':'Dzhamuha-develop'}
    def test_trusted_push(self):self.assertTrue(accepted(self.event))
    def test_fork_same_branch(self):
        self.event['github.event.workflow_run.head_repository.full_name']='attacker/fork';self.assertFalse(accepted(self.event))
    def test_untrusted_events(self):
        for value in ['pull_request','pull_request_target','workflow_dispatch','issue_comment','']:
            with self.subTest(value=value):
                e={**self.event,'github.event.workflow_run.event':value};self.assertFalse(accepted(e))
    def test_failed_or_incomplete_upstream(self):
        for value in ['failure','cancelled','skipped','action_required','']:
            with self.subTest(value=value):self.assertFalse(accepted({**self.event,'github.event.workflow_run.conclusion':value}))
    def test_other_or_missing_branch(self):
        for value in ['main','feature','']:
            self.assertFalse(accepted({**self.event,'github.event.workflow_run.head_branch':value}))
    def test_missing_repository_fails_closed(self):
        del self.event['github.event.workflow_run.head_repository.full_name'];self.assertFalse(accepted(self.event))
    def test_publisher_scripts_are_not_from_trigger_sha(self):
        text,_=condition();checkouts=re.findall(r'      - uses: actions/checkout@[^\n]+\n        with:\n(.*?)(?=\n      - |\Z)',text,re.S)
        self.assertEqual(len(checkouts),2)
        self.assertIn('ref: ${{ github.workflow_sha }}',checkouts[0])
        self.assertNotIn('workflow_run.head_sha',checkouts[0])
        self.assertIn('path: release-source',checkouts[1])
        for checkout in checkouts:self.assertIn('persist-credentials: false',checkout)
        self.assertIn('Get-Content release-source/version.json',text)
    def test_stable_release_requires_public_signature(self):
        text,_=condition();self.assertIn('verify-public-windows-signature.ps1',text)
        self.assertIn("steps.version.outputs.draft == 'false'",text)
    def test_existing_release_probe_is_fail_closed_and_assets_are_immutable(self):
        text,_=condition()
        self.assertIn('./tools/check-existing-release.ps1 -Repository $env:GITHUB_REPOSITORY -Tag $tag',text)
        self.assertNotIn('gh release view',text)
        self.assertIn('overwrite_files: false',text)
        self.assertLess(text.index('./tools/check-existing-release.ps1'),text.index('"tag=$tag"'))
        readiness=(ROOT/'tools/test-release-readiness.ps1').read_text(encoding='utf-8')
        self.assertIn("'test-existing-release.ps1'",readiness)
    def test_required_package_gate_runs_before_merge_without_path_skips(self):
        text=WORKFLOW.with_name('windows-release-gate.yml').read_text(encoding='utf-8')
        events=text.split('\npermissions:',1)[0]
        for event in ['push','pull_request']:
            self.assertRegex(events,rf'(?m)^  {event}:\n(?:    #[^\n]*\n)*    branches: \[Dzhamuha-develop\]')
        self.assertNotRegex(events,r'(?m)^\s+(paths|paths-ignore):')
        self.assertNotIn('pull_request_target:',events)
        self.assertIn('persist-credentials: false',text)
        self.assertNotIn('contents: write',text)

class FlutterActionPins(unittest.TestCase):
    def test_floating_nested_cache_is_rejected(self):
        for reference in ['actions/cache@v5','actions/cache@main','actions/cache@caa2961']:
            with self.subTest(reference=reference), self.assertRaises(AssertionError):
                require_action_pins('runs:\n  using: composite\n  steps:\n    - uses: '+reference+'\n')
        require_action_pins('    - uses: actions/cache@caa296126883cff596d87d8935842f9db880ef25\n')

    def test_workflows_and_local_actions_require_full_pins(self):
        files=list((ROOT/'.github/workflows').glob('*.yml'))
        files+=list((ROOT/'.github/workflows').glob('*.yaml'))
        for filename in ['action.yml','action.yaml']:
            files+=list((ROOT/'.github/actions').rglob(filename))
        self.assertTrue(files)
        for path in files:
            with self.subTest(path=path.relative_to(ROOT)):
                text=path.read_text(encoding='utf-8')
                require_action_pins(text)
                for reference in action_references(text):
                    if reference.startswith('./'):
                        target=(ROOT/reference).resolve()
                        self.assertTrue(target.is_relative_to(ROOT.resolve()))
                        self.assertTrue(any((target/name).is_file() for name in ['action.yml','action.yaml']))

    def test_flutter_callers_keep_version_and_cache(self):
        for name in ['ci.yml','windows-release-gate.yml']:
            with self.subTest(workflow=name):
                text=WORKFLOW.with_name(name).read_text(encoding='utf-8')
                self.assertEqual(text.count('uses: ./.github/actions/setup-flutter'),1)
                self.assertNotIn('uses: subosito/flutter-action@',text)
                self.assertRegex(text,r'uses: \./\.github/actions/setup-flutter\n\s+with:\n\s+flutter-version: "3\.47\.1"\n\s+channel: stable\n\s+cache: true')
                self.assertLess(text.index('uses: actions/checkout@'),text.index('uses: ./.github/actions/setup-flutter'))

    def test_vendored_manifest_only_patches_cache_and_preserves_license(self):
        action=ROOT/'.github/actions/setup-flutter'
        source=json.loads((action/'provenance.json').read_text(encoding='utf-8'))
        self.assertEqual(source['repository'],'https://github.com/subosito/flutter-action')
        self.assertEqual(source['revision'],'1a449444c387b1966244ae4d4f8c696479add0b2')
        self.assertEqual(source['cache']['repository'],'https://github.com/actions/cache')
        self.assertRegex(source['cache']['revision'],r'^[0-9a-f]{40}$')
        manifest=(action/'action.yaml').read_text(encoding='utf-8')
        pinned='actions/cache@'+source['cache']['revision']
        self.assertEqual(action_references(manifest),[pinned,pinned])
        original=manifest.replace(pinned,'actions/cache@'+source['cache']['upstreamReference'])
        self.assertEqual(hashlib.sha256(original.encode()).hexdigest(),source['files']['action.yaml'])
        for filename in ['setup.sh','LICENSE']:
            self.assertEqual(hashlib.sha256((action/filename).read_bytes()).hexdigest(),source['files'][filename])
        self.assertIn('Copyright (c) 2019 Alif Rachmawadi',(action/'LICENSE').read_text(encoding='utf-8'))

if __name__=='__main__':unittest.main()
