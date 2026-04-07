import json
import unittest
from unittest.mock import patch

from cmux_harness.routes import status_summary


class CompletedProcess:
    def __init__(self, stdout='', returncode=0):
        self.stdout = stdout
        self.returncode = returncode


class TestStatusSummary(unittest.TestCase):
    def test_builds_executing_summary_from_task_review_message_and_git_state(self):
        objective = {
            'id': 'objective-1',
            'goal': 'Add status summary support',
            'status': 'executing',
            'branchName': 'feature/status-summary',
            'worktreePath': '/tmp/repo',
            'tasks': [
                {'id': 'task-1', 'title': 'Add backend endpoint', 'status': 'executing', 'reviewCycles': 0},
                {'id': 'task-2', 'title': 'Add UI card', 'status': 'queued', 'reviewCycles': 0},
            ],
        }
        messages = [
            {'timestamp': '2026-04-07T07:00:00+00:00', 'type': 'system', 'content': 'Starting objective', 'metadata': {}},
            {'timestamp': '2026-04-07T07:05:00+00:00', 'type': 'progress', 'content': 'Implemented the endpoint shape.', 'metadata': {'task_id': 'task-1'}},
        ]

        def fake_read_task_file(objective_id, task_id, filename):
            if task_id == 'task-1' and filename == 'review.json':
                return json.dumps({'verdict': 'pass', 'issues': []})
            return None

        def fake_run(command, capture_output, text, timeout, check):
            tail = tuple(command[-4:])
            if command[-3:] == ['status', '--short', '--branch']:
                return CompletedProcess('## feature/status-summary\nM  cmux_harness/server.py\n M cmux_harness/static/orchestrator.js\n?? tests/test_status_summary.py\n')
            if tail == ('diff', '--stat', '--',):
                return CompletedProcess(' cmux_harness/static/orchestrator.js | 42 ++++++++++++++++++')
            if tail == ('--stat', '--cached', '--'):
                return CompletedProcess(' cmux_harness/server.py | 12 ++++++')
            if command[-3:] == ['-1', '--pretty=%h %s']:
                return CompletedProcess('abc123 wire status summary endpoint')
            return CompletedProcess('')

        with patch('cmux_harness.routes.status_summary.objectives.read_task_file', side_effect=fake_read_task_file), patch('cmux_harness.routes.status_summary.subprocess.run', side_effect=fake_run):
            summary = status_summary.build_status_summary('objective-1', objective, messages)

        self.assertEqual(summary['stage']['code'], 'executing')
        self.assertIn('Executing', summary['tldr'])
        self.assertIn('changed files', summary['tldr'])
        self.assertEqual(summary['justHappened'], 'Implemented the endpoint shape.')
        self.assertIn('Add backend endpoint', summary['now'])
        self.assertIn('queued task', summary['next'])
        self.assertEqual(summary['signals']['git']['changedFiles'], 3)
        self.assertEqual(summary['signals']['reviews']['passed'], 1)

    def test_surfaces_blockers_for_plan_review_and_failed_tasks(self):
        objective = {
            'id': 'objective-2',
            'goal': 'Finish orchestrator objective status',
            'status': 'plan_review',
            'worktreePath': '/tmp/repo',
            'tasks': [
                {'id': 'task-1', 'title': 'Plan the work', 'status': 'failed', 'reviewCycles': 2},
            ],
        }
        messages = [
            {'timestamp': '2026-04-07T07:10:00+00:00', 'type': 'approval', 'content': 'Approval needed to continue task-1', 'metadata': {'task_id': 'task-1'}},
            {'timestamp': '2026-04-07T07:12:00+00:00', 'type': 'alert', 'content': 'Task task-1 failed review 3 times. Needs your attention.', 'metadata': {'task_id': 'task-1'}},
        ]

        def fake_read_task_file(objective_id, task_id, filename):
            if filename == 'review.json':
                return json.dumps({'verdict': 'fail', 'issues': ['Missing refresh button on the status card']})
            return None

        with patch('cmux_harness.routes.status_summary.objectives.read_task_file', side_effect=fake_read_task_file), patch('cmux_harness.routes.status_summary.subprocess.run', return_value=CompletedProcess('')):
            summary = status_summary.build_status_summary('objective-2', objective, messages)

        self.assertEqual(summary['stage']['label'], 'Plan review')
        self.assertIn('Approve the plan', summary['next'])
        self.assertTrue(summary['blockers'])
        self.assertIn('Missing refresh button on the status card', ' '.join(summary['blockers']))
        self.assertIn('blocker', summary['tldr'])


if __name__ == '__main__':
    unittest.main()
