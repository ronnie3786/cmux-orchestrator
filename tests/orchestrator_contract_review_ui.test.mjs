import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const source = fs.readFileSync(
  path.resolve(__dirname, '../cmux_harness/static/orchestrator.js'),
  'utf8'
);

function extractFunction(name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `Could not find function ${name}`);

  let index = source.indexOf('{', start);
  assert.notEqual(index, -1, `Could not find body for function ${name}`);

  let depth = 0;
  let inSingle = false;
  let inDouble = false;
  let inTemplate = false;
  let inLineComment = false;
  let inBlockComment = false;
  let escaped = false;

  for (; index < source.length; index += 1) {
    const char = source[index];
    const next = source[index + 1];

    if (inLineComment) {
      if (char === '\n') inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (char === '*' && next === '/') {
        inBlockComment = false;
        index += 1;
      }
      continue;
    }
    if (inSingle) {
      if (!escaped && char === "'") inSingle = false;
      escaped = !escaped && char === '\\';
      continue;
    }
    if (inDouble) {
      if (!escaped && char === '"') inDouble = false;
      escaped = !escaped && char === '\\';
      continue;
    }
    if (inTemplate) {
      if (!escaped && char === '`') inTemplate = false;
      escaped = !escaped && char === '\\';
      continue;
    }

    escaped = false;
    if (char === '/' && next === '/') {
      inLineComment = true;
      index += 1;
      continue;
    }
    if (char === '/' && next === '*') {
      inBlockComment = true;
      index += 1;
      continue;
    }
    if (char === "'") {
      inSingle = true;
      continue;
    }
    if (char === '"') {
      inDouble = true;
      continue;
    }
    if (char === '`') {
      inTemplate = true;
      continue;
    }
    if (char === '{') {
      depth += 1;
      continue;
    }
    if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return source.slice(start, index + 1);
      }
    }
  }

  throw new Error(`Could not parse function ${name}`);
}

function createRendererHarness(objectiveStatus) {
  const context = vm.createContext({
    __state: {
      activeObjective: { status: objectiveStatus },
      messages: []
    }
  });

  const script = [
    `
    const state = __state;
    function esc(value) {
      return String(value == null ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }
    `,
    extractFunction('latestMessageIdOfType'),
    extractFunction('reviewCardState'),
    extractFunction('normalizeContractEvaluationVerdict'),
    extractFunction('summarizeContractEvaluation'),
    extractFunction('contractEvaluationBadge'),
    extractFunction('contractReviewBannerState'),
    extractFunction('renderContractEvaluationBlock'),
    extractFunction('renderContractReviewCard'),
    `
    globalThis.__exports = {
      state,
      renderContractReviewCard
    };
    `
  ].join('\n');

  vm.runInContext(script, context);
  return context.__exports;
}

function buildMessage(contracts, id = 'contract-review-1') {
  return {
    id,
    type: 'contract_review',
    metadata: { contracts }
  };
}

test('contract review card shows active all-pass evaluator banner and per-task approval state', () => {
  const harness = createRendererHarness('contract_review');
  const message = buildMessage([
    {
      taskId: 'task-1',
      title: 'First task',
      acceptanceCriteria: 'Feature works.',
      buildVerification: 'Run build.',
      functionalTestHints: 'Tap through the main flow.',
      passFailThreshold: 'Fail on regression.',
      evaluationVerdict: 'pass',
      evaluationSummary: 'Concrete and testable.',
      evaluationIssues: []
    }
  ]);
  harness.state.messages = [message];

  const html = harness.renderContractReviewCard(message);

  assert.match(html, /All approved by AI evaluator/);
  assert.match(html, /Human approval is still required before execution can start\./);
  assert.match(html, /AI Approved/);
  assert.match(html, /Concrete and testable\./);
  assert.match(html, /Approve Contracts/);
});

test('contract review card shows evaluator failure banner and issue list during human fallback', () => {
  const harness = createRendererHarness('contract_review');
  const message = buildMessage([
    {
      taskId: 'task-1',
      title: 'Weak contract',
      acceptanceCriteria: 'Do the thing.',
      buildVerification: '/exp-project-run',
      functionalTestHints: 'Test it.',
      passFailThreshold: 'Should probably work.',
      evaluationVerdict: 'fail',
      evaluationSummary: 'Too vague.',
      evaluationIssues: ['Acceptance criteria are not concrete enough.']
    }
  ]);
  harness.state.messages = [message];

  const html = harness.renderContractReviewCard(message);

  assert.match(html, /Evaluator found issues/);
  assert.match(html, /Human review is required before execution can start\./);
  assert.match(html, /Needs Fixes/);
  assert.match(html, /Too vague\./);
  assert.match(html, /Acceptance criteria are not concrete enough\./);
});

test('contract review card shows execution-moved-forward copy after approval path closes', () => {
  const harness = createRendererHarness('executing');
  const message = buildMessage([
    {
      taskId: 'task-1',
      title: 'Approved contract',
      acceptanceCriteria: 'Works end to end.',
      buildVerification: 'Run build.',
      functionalTestHints: 'Run the happy path.',
      passFailThreshold: 'Fail on broken flow.',
      evaluationVerdict: 'pass',
      evaluationSummary: 'Looks good.',
      evaluationIssues: []
    }
  ]);
  harness.state.messages = [message];

  const html = harness.renderContractReviewCard(message);

  assert.match(html, /All approved by AI evaluator/);
  assert.match(html, /execution moved forward\./);
  assert.match(html, /Approved/);
  assert.doesNotMatch(html, /Approve Contracts/);
});

test('contract review card renders a neutral evaluator state when verdict metadata is missing', () => {
  const harness = createRendererHarness('contract_review');
  const message = buildMessage([
    {
      taskId: 'task-1',
      title: 'Legacy contract',
      acceptanceCriteria: 'Still render.',
      buildVerification: 'Run build.',
      functionalTestHints: 'Verify output.',
      passFailThreshold: 'Fail on mismatch.',
      evaluationSummary: '',
      evaluationIssues: []
    }
  ]);
  harness.state.messages = [message];

  const html = harness.renderContractReviewCard(message);

  assert.match(html, /No evaluator result/);
  assert.match(html, /No Verdict/);
  assert.match(html, /No evaluator result recorded for this contract\./);
});
