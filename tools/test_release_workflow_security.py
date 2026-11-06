"""Evaluate the actual pre-checkout publishing condition against hostile events."""
import re,unittest
from pathlib import Path

WORKFLOW=Path(__file__).resolve().parents[1]/'.github/workflows/release.yml'

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

if __name__=='__main__':unittest.main()
