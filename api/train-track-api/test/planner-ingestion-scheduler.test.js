import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { startTimetableIngestion } from '../lib/planner/ingestion-scheduler.js';
import { timetableIngestionConfig } from '../lib/planner/ingestion-source.js';

function fakeTimers() {
  let now = 0, sequence = 0;
  const pending = new Map(), created = [];
  function add(callback, delay, interval) {
    const timer = { id: ++sequence, callback, delay, due: now + delay, interval, unreferenced: false, unref() { this.unreferenced = true; } };
    pending.set(timer.id, timer); created.push(timer); return timer;
  }
  const timers = { setTimeout: (callback, delay) => add(callback, delay, false), clearTimeout: timer => pending.delete(timer.id),
    setInterval: (callback, delay) => add(callback, delay, true), clearInterval: timer => pending.delete(timer.id) };
  function advance(milliseconds) {
    const end = now + milliseconds;
    for (;;) {
      const next = [...pending.values()].filter(timer => timer.due <= end).sort((a, b) => a.due - b.due || a.id - b.id)[0];
      if (!next) break;
      now = next.due;
      if (next.interval) next.due += next.delay; else pending.delete(next.id);
      next.callback();
    }
    now = end;
  }
  return { timers, advance, pending, created };
}

function fakeChild({ pid = 1234 } = {}) {
  const child = new EventEmitter();
  Object.assign(child, { pid, signals: [], stdout: new PassThrough(), stderr: new PassThrough(), drains: 0,
    kill(signal) { child.signals.push(signal); return true; } });
  for (const stream of [child.stdout, child.stderr]) {
    const resume = stream.resume;
    stream.resume = function () { child.drains++; return resume.call(this); };
  }
  return child;
}

function setup(t, overrides = {}) {
  const clock = fakeTimers(), calls = [], logs = [];
  const logger = { info: (...args) => logs.push(args.join(' ')), warn: (...args) => logs.push(args.join(' ')) };
  const spawn = (...args) => { const child = fakeChild(); calls.push({ args, child }); return child; };
  const scheduler = startTimetableIngestion({ config: { enabled: true, configured: true, dataDirectory: '/test/data with spaces', intervalSeconds: 3600, timeoutMs: 900000, ...overrides.config },
    spawn: overrides.spawn ?? spawn, logger, timers: clock.timers });
  t.after(() => { scheduler.stop(); for (const call of calls) call.child.emit('close', null); });
  return { ...clock, scheduler, calls, logs };
}

test('disabled ingestion does not create timers or processes, including manual checks', t => {
  const fixture = setup(t, { config: { enabled: false } });
  assert.equal(fixture.calls.length, 0); assert.equal(fixture.pending.size, 0);
  assert.equal(fixture.scheduler.checkNow(), false);
  fixture.advance(7200000);
  assert.equal(fixture.calls.length, 0);
});

test('enabled scheduler checks immediately and hourly in a bounded separate process, inherits env, drains output and unrefs timers', t => {
  const fixture = setup(t), [call] = fixture.calls;
  assert.equal(fixture.calls.length, 1);
  assert.deepEqual(call.args.slice(0, 2), [process.execPath, ['--max-old-space-size=512', 'scripts/planner.js', 'sync', '--data-dir', '/test/data with spaces']]);
  assert.deepEqual(call.args[2], { cwd: fileURLToPath(new URL('../', import.meta.url)), env: process.env, shell: false, stdio: ['ignore', 'pipe', 'pipe'] });
  assert.equal(call.child.drains, 2);
  assert.equal(fixture.created.every(timer => timer.unreferenced), true);
  call.child.emit('close', 0);
  fixture.advance(3599999); assert.equal(fixture.calls.length, 1);
  fixture.advance(1); assert.equal(fixture.calls.length, 2);
  assert.match(fixture.logs.join('\n'), /Timetable check completed/);
});

test('manual and timer checks cannot overlap; only close releases a running child, not an error event', t => {
  const fixture = setup(t), first = fixture.calls[0].child;
  assert.equal(fixture.scheduler.checkNow(), false);
  first.emit('error', new Error('secret credentials should never appear'));
  assert.equal(fixture.scheduler.checkNow(), false);
  fixture.advance(3600000); assert.equal(fixture.calls.length, 1);
  first.emit('close', 1);
  assert.equal(fixture.scheduler.checkNow(), true);
  assert.equal(fixture.calls.length, 2);
  assert.equal(fixture.scheduler.checkNow(), false);
  assert.equal(fixture.logs.join('\n').includes('secret credentials'), false);
});

test('15 minute timeout sends SIGTERM and then SIGKILL after 5 seconds; close clears timers and permits retry', t => {
  const fixture = setup(t), child = fixture.calls[0].child;
  fixture.advance(899999); assert.deepEqual(child.signals, []);
  fixture.advance(1); assert.deepEqual(child.signals, ['SIGTERM']);
  fixture.advance(4999); assert.deepEqual(child.signals, ['SIGTERM']);
  fixture.advance(1); assert.deepEqual(child.signals, ['SIGTERM', 'SIGKILL']);
  assert.equal(fixture.scheduler.checkNow(), false);
  child.emit('close', null);
  assert.equal(fixture.pending.size, 1);
  assert.equal(fixture.scheduler.checkNow(), true);
  assert.match(fixture.logs.join('\n'), /time limit/);
});

test('a cooperative timeout exit cancels SIGKILL escalation', t => {
  const fixture = setup(t), child = fixture.calls[0].child;
  fixture.advance(900000); child.emit('close', null);
  fixture.advance(5000);
  assert.deepEqual(child.signals, ['SIGTERM']);
  assert.equal(fixture.pending.size, 1);
});

test('stop cancels future checks and deadlines, terminates active child and is idempotent', t => {
  const fixture = setup(t), child = fixture.calls[0].child;
  fixture.scheduler.stop(); fixture.scheduler.stop();
  assert.equal(fixture.scheduler.checkNow(), false);
  assert.deepEqual(child.signals, ['SIGTERM']);
  assert.equal(fixture.pending.size, 1);
  fixture.advance(5000); assert.deepEqual(child.signals, ['SIGTERM', 'SIGKILL']);
  child.emit('close', null);
  assert.equal(fixture.pending.size, 0);
  fixture.advance(7200000); assert.equal(fixture.calls.length, 1);
});

test('spawn failures and child output are sanitized, retry remains available and explicit enabled ignores missing credentials', t => {
  const fixture = setup(t, { config: { configured: false } }), child = fixture.calls[0].child;
  child.stdout.write('secret-access-key stdout\n'); child.stderr.write('private-token stderr\n');
  child.emit('close', 7);
  assert.match(fixture.logs.join('\n'), /exit code 7/);
  assert.doesNotMatch(fixture.logs.join('\n'), /secret-access-key|private-token/);
  assert.equal(fixture.scheduler.checkNow(), true);
  const thrown = setup(t, { spawn() { throw new Error('credential-dump'); } });
  assert.match(thrown.logs.join('\n'), /exit code unavailable/);
  assert.doesNotMatch(thrown.logs.join('\n'), /credential-dump/);
  assert.equal(thrown.scheduler.checkNow(), true);
  assert.equal(thrown.pending.size, 1);
});

test('a failed spawn error without pid releases its slot and duplicate close does not log twice', t => {
  const children = [], fixture = setup(t, { spawn() { const child = fakeChild({ pid: null }); children.push(child); return child; } });
  children[0].emit('error', new Error('never log this secret'));
  const afterError = fixture.logs.length;
  children[0].emit('close', -2);
  assert.equal(fixture.logs.length, afterError);
  assert.equal(fixture.scheduler.checkNow(), true);
  children[1].emit('close', 0);
  assert.doesNotMatch(fixture.logs.join('\n'), /never log this secret/);
});

test('default configuration stays disabled without credentials and accepts explicit enablement', () => {
  assert.equal(timetableIngestionConfig({}).enabled, false);
  assert.equal(timetableIngestionConfig({ PLANNER_INGESTION_ENABLED: 'true' }).enabled, true);
});
