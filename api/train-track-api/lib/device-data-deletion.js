import { COLLECTIONS, getMongoCollection } from './mongo-client.js';

const DEVICE_REFERENCE_PATHS = [
    'device_id',
    'deviceId',
    'subscription.deviceId',
    'before.deviceId',
    'after.deviceId',
    'context.device_id',
    'context.deviceId',
    'context.target_device_id',
    'context.targetDeviceId',
    'context.original_context.device_id',
    'context.original_context.deviceId',
    'metadata.device_id',
    'payload.device_id',
    'payload.deviceId',
    'payload.aps.content-state.deviceID',
    'payload.aps.content-state.deviceId'
];

const SUBSCRIPTION_REFERENCE_PATHS = [
    'subscription_id',
    'subscription.id',
    'before.id',
    'after.id',
    'context.subscription_id',
    'context.original_context.subscription_id',
    'metadata.subscription_id',
    'payload.subscription_id'
];

const ACTIVITY_REFERENCE_PATHS = [
    'activity_id',
    'context.activity_id',
    'context.target_activity_id',
    'context.original_context.activity_id',
    'payload.activity_id',
    'payload.aps.content-state.activityID',
    'payload.aps.content-state.activityId'
];

const EVENT_COLLECTIONS = [
    COLLECTIONS.notificationEvents,
    COLLECTIONS.pushAuditEvents,
    COLLECTIONS.liveActivityPayloads,
    COLLECTIONS.subscriptionAuditEvents
];

export class DeviceDataDeletionService {
    constructor({
        getCollection = getMongoCollection,
        purgeRuntimeState = async () => ({}),
        deleteAuditLogEntries = async () => ({ deleted: 0 }),
        markDeviceDataDeleted = () => {},
        finishDeviceDataDeletion = () => {},
        forgetDeviceLastSeen = () => false
    } = {}) {
        this.getCollection = getCollection;
        this.purgeRuntimeState = purgeRuntimeState;
        this.deleteAuditLogEntries = deleteAuditLogEntries;
        this.markDeviceDataDeleted = markDeviceDataDeleted;
        this.finishDeviceDataDeletion = finishDeviceDataDeletion;
        this.forgetDeviceLastSeen = forgetDeviceLastSeen;
        this.activeDeletions = new Map();
    }

    async deleteAllForDevice(deviceId) {
        const normalizedDeviceId = normalizeDeviceId(deviceId);
        if (!normalizedDeviceId) {
            throw new Error('deviceId is required');
        }

        const existingDeletion = this.activeDeletions.get(normalizedDeviceId);
        if (existingDeletion) return existingDeletion;

        const deletion = this.performDeletion(normalizedDeviceId);
        this.activeDeletions.set(normalizedDeviceId, deletion);
        try {
            return await deletion;
        } finally {
            if (this.activeDeletions.get(normalizedDeviceId) === deletion) {
                this.activeDeletions.delete(normalizedDeviceId);
            }
        }
    }

    async performDeletion(normalizedDeviceId) {
        this.markDeviceDataDeleted(normalizedDeviceId);
        const associations = await this.findAssociations(normalizedDeviceId);

        // Stop in-memory pollers from producing more device-linked records before
        // the final persistence and JSONL sweeps. These removals deliberately do
        // not emit audit events, because those events would immediately need deletion.
        const runtime = await this.purgeRuntimeState(normalizedDeviceId);

        const deletionPhases = buildDeletionPhases(normalizedDeviceId, associations);
        const deletedByCollection = {};
        await this.executeDeletionPlan(deletionPhases.dependentRecords, deletedByCollection);

        const auditLog = await this.deleteAuditLogEntries(normalizedDeviceId, {
            subscriptionIds: associations.subscriptionIds,
            activityIds: associations.activityIds
        });

        // These records are the lookup source for indirect subscription, activity
        // and token references. Keep them until every dependent store and audit log
        // has succeeded so an idempotent retry can reconstruct the same associations.
        await this.executeDeletionPlan(deletionPhases.associationSources, deletedByCollection);

        // The metrics middleware sees the deletion request before this handler.
        // Forget the identifier only after all persistence has been scrubbed.
        const metricsLastSeen = Boolean(this.forgetDeviceLastSeen(normalizedDeviceId));
        this.finishDeviceDataDeletion(normalizedDeviceId);

        return {
            collections: deletedByCollection,
            persistedRecords: Object.values(deletedByCollection).reduce((sum, count) => sum + count, 0),
            auditLog,
            runtime,
            metricsLastSeen
        };
    }

    async findAssociations(deviceId) {
        const [subscriptions, liveActivities, pushToStartTokens] = await Promise.all([
            this.findDocuments(
                COLLECTIONS.notificationSubscriptions,
                { deviceId },
                { _id: 1, id: 1, pushToken: 1 }
            ),
            this.findDocuments(
                COLLECTIONS.liveActivitySessions,
                { deviceId },
                { activityId: 1, pushToken: 1 }
            ),
            this.findDocuments(
                COLLECTIONS.pushToStartTokens,
                { $or: [{ _id: deviceId }, { deviceId }] },
                { pushToStartToken: 1 }
            )
        ]);

        return {
            subscriptionIds: uniqueStrings(subscriptions.flatMap((record) => [record?._id, record?.id])),
            activityIds: uniqueStrings(liveActivities.map((record) => record?.activityId)),
            tokens: uniqueStrings([
                ...subscriptions.map((record) => record?.pushToken),
                ...liveActivities.map((record) => record?.pushToken),
                ...pushToStartTokens.map((record) => record?.pushToStartToken)
            ])
        };
    }

    async findDocuments(collectionName, filter, projection) {
        const collection = await this.getCollection(collectionName);
        return collection.find(filter).project(projection).toArray();
    }

    async executeDeletionPlan(plan, deletedByCollection) {
        const deletionResults = await Promise.allSettled(plan.map(async ({ collectionName, filter }) => {
            const collection = await this.getCollection(collectionName);
            const result = await collection.deleteMany(filter);
            deletedByCollection[collectionName] = Number(result?.deletedCount) || 0;
        }));
        const failedDeletion = deletionResults.find((result) => result.status === 'rejected');
        if (failedDeletion) throw failedDeletion.reason;
    }
}

export function buildDeletionPhases(deviceId, associations = {}) {
    const subscriptionIds = uniqueStrings(associations.subscriptionIds);
    const activityIds = uniqueStrings(associations.activityIds);
    const tokens = uniqueStrings(associations.tokens);
    const eventFilter = referenceFilter({ deviceId, subscriptionIds, activityIds, tokens });

    return {
        dependentRecords: [
            {
                collectionName: COLLECTIONS.devicePreferences,
                filter: { $or: [{ _id: deviceId }, { device_id: deviceId }] }
            },
            ...EVENT_COLLECTIONS.map((collectionName) => ({ collectionName, filter: eventFilter })),
            {
                collectionName: COLLECTIONS.geofenceEvents,
                filter: { device_id: deviceId }
            },
            {
                collectionName: COLLECTIONS.holidayMode,
                filter: { $or: [{ _id: deviceId }, { deviceId }] }
            }
        ],
        associationSources: [
            {
                collectionName: COLLECTIONS.notificationSubscriptions,
                filter: { deviceId }
            },
            {
                collectionName: COLLECTIONS.pushToStartTokens,
                filter: { $or: [{ _id: deviceId }, { deviceId }] }
            },
            {
                collectionName: COLLECTIONS.liveActivitySessions,
                filter: { deviceId }
            }
        ]
    };
}

function referenceFilter({ deviceId, subscriptionIds, activityIds, tokens }) {
    const references = DEVICE_REFERENCE_PATHS.map((path) => ({ [path]: deviceId }));
    addInReferences(references, SUBSCRIPTION_REFERENCE_PATHS, subscriptionIds);
    addInReferences(references, ACTIVITY_REFERENCE_PATHS, activityIds);
    addInReferences(references, ['token'], tokenReferences(tokens));
    return { $or: references };
}

function addInReferences(references, paths, values) {
    if (!Array.isArray(values) || values.length === 0) return;
    for (const path of paths) {
        references.push({ [path]: { $in: values } });
    }
}

function tokenReferences(tokens) {
    return uniqueStrings(tokens.flatMap((token) => [token, maskToken(token)]));
}

function maskToken(token) {
    if (typeof token !== 'string' || token.length === 0) return null;
    if (token.length <= 10) return `${token.slice(0, 3)}***`;
    return `${token.slice(0, 8)}...${token.slice(-6)}`;
}

function uniqueStrings(values = []) {
    return Array.from(new Set(
        values
            .filter((value) => typeof value === 'string')
            .map((value) => value.trim())
            .filter(Boolean)
    ));
}

function normalizeDeviceId(value) {
    return typeof value === 'string' ? value.trim() : '';
}
