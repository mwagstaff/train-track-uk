#!/usr/bin/env node
import { PlannerService } from '../lib/planner/service.js';
import { closeMongoClient } from '../lib/mongo-client.js';
import { loadPlannerTargets, PlannerTargetManager } from '../lib/planner-targets.js';

const [command, requestedTarget] = process.argv.slice(2);
if (!['status', 'select'].includes(command) || command === 'select' && !requestedTarget
    || command === 'status' && requestedTarget) {
    console.error('Usage: node scripts/planner-target-admin.js status|select <target-id>');
    process.exit(2);
}
if (process.env.PLANNER_HOST_ID !== 'sky' || !process.env.PLANNER_TARGETS_FILE) {
    console.error('Run this command on Sky with its deployed API environment loaded.');
    process.exit(2);
}

const embeddedService = process.env.PLANNER_EMBEDDED_ENABLED === 'false' ? null : new PlannerService();
try {
    const targets = await loadPlannerTargets(process.env, embeddedService);
    const manager = new PlannerTargetManager({ targets,
        defaultTargetId: process.env.PLANNER_DEFAULT_TARGET || 'sky',
        forceTargetId: process.env.PLANNER_FORCE_TARGET || null });
    const current = await manager.init();
    if (current.stale || !current.targetId) throw new Error('Persisted planner target selection is unavailable.');
    if (command === 'select') {
        if (current.targetId === requestedTarget) throw new Error(`${requestedTarget} is already selected.`);
        const selection = await manager.select({ targetId: requestedTarget, revision: current.revision,
            operator: process.env.USER || 'sky-operator' });
        console.log(JSON.stringify({ targetId: selection.targetId, revision: selection.revision,
            previousTargetId: selection.previousTargetId, ready: true }, null, 2));
        // Allow the supplementary audit insert to finish before closing Mongo.
        await new Promise(resolve => setTimeout(resolve, 100));
    } else {
        const health = await manager.health(current.targetId);
        console.log(JSON.stringify({ targetId: current.targetId, revision: current.revision,
            forced: current.forced, ready: health.ready, readinessReason: health.readinessReason,
            hostId: health.hostId, datasetVersion: health.dataset?.version ?? null }, null, 2));
        if (!health.ready) process.exitCode = 1;
    }
} catch (error) {
    console.error(error?.message || error);
    process.exitCode = 1;
} finally {
    embeddedService?.close();
    await closeMongoClient();
}
