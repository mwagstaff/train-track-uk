import { spawn as realSpawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { timetableIngestionConfig } from './ingestion-source.js';

const API_DIRECTORY = fileURLToPath(new URL('../../', import.meta.url));
const DEFAULT_TIMERS = { setInterval, clearInterval, setTimeout, clearTimeout };
const TERMINATION_GRACE_MS = 5000;

// Importing/parsing the national timetable must never run on Express's event
// loop. The CLI owns persistence, locking and validation; this owns scheduling.
export function startTimetableIngestion({ config = timetableIngestionConfig(), spawn = realSpawn, logger = console, timers = DEFAULT_TIMERS } = {}) {
  let active = null, interval = null, stopped = false;
  const log = (level, message) => logger[level]?.(`[planner-ingestion] ${message}`);
  const unref = timer => { timer?.unref?.(); return timer; };

  function clearJobTimers(job) {
    if (job.deadline) timers.clearTimeout(job.deadline);
    if (job.killDeadline) timers.clearTimeout(job.killDeadline);
    job.deadline = job.killDeadline = null;
  }

  function finish(job, code) {
    if (active !== job) return;
    clearJobTimers(job);
    active = null;
    if (job.termination === 'stopped') return;
    if (job.termination === 'timeout') log('warn', 'Timetable check ended after its time limit. Inspect ingestion state for details.');
    else if (code === 0 && !job.failed) log('info', 'Timetable check completed.');
    else log('warn', `Timetable check failed (exit code ${Number.isSafeInteger(code) && code >= 0 ? code : 'unavailable'}). Inspect ingestion state for details.`);
  }

  function kill(job, signal) {
    try { job.child.kill(signal); }
    catch { log('warn', 'Could not signal the timetable check child process.'); }
  }

  function terminate(job, reason) {
    if (active !== job || job.termination) return;
    job.termination = reason;
    if (job.deadline) timers.clearTimeout(job.deadline);
    job.deadline = null;
    kill(job, 'SIGTERM');
    // A cooperative CLI cleans up staging/locks on SIGTERM. Bound shutdown even
    // if it is stuck in I/O or unresponsive synchronous work.
    if (active === job) job.killDeadline = unref(timers.setTimeout(() => {
      job.killDeadline = null;
      if (active === job) kill(job, 'SIGKILL');
    }, TERMINATION_GRACE_MS));
  }

  function checkNow() {
    if (stopped || !config.enabled || active) return false;
    const job = { child: null, deadline: null, killDeadline: null, termination: null, failed: false };
    active = job;
    try {
      job.child = spawn(process.execPath, ['--max-old-space-size=512', 'scripts/planner.js', 'sync', '--data-dir', config.dataDirectory], {
        cwd: API_DIRECTORY, env: process.env, shell: false, stdio: ['ignore', 'pipe', 'pipe']
      });
      // Never retain or echo arbitrary child output: upstream errors can contain
      // credentials/URLs. The ingestion state file is the structured audit log.
      for (const output of [job.child.stdout, job.child.stderr]) {
        output?.on('error', () => {});
        output?.resume();
      }
      job.child.once('error', () => {
        job.failed = true;
        if (!job.child.pid) finish(job, null);
        // If a running child reports an error, keep its single-flight slot
        // until close; an error event alone does not prove the process exited.
      });
      job.child.once('close', code => finish(job, code));
      job.deadline = unref(timers.setTimeout(() => terminate(job, 'timeout'), config.timeoutMs ?? 15 * 60 * 1000));
      log('info', 'Timetable check started in a separate process.');
    } catch {
      job.failed = true;
      finish(job, null);
    }
    return true;
  }

  function stop() {
    if (stopped) return;
    stopped = true;
    if (interval) timers.clearInterval(interval);
    interval = null;
    if (active) terminate(active, 'stopped');
  }

  if (config.enabled) {
    interval = unref(timers.setInterval(checkNow, (config.intervalSeconds ?? 3600) * 1000));
    checkNow();
  }
  return { checkNow, stop };
}
