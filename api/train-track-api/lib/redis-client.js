import Redis from 'ioredis';

const redis = new Redis({
    host: process.env.REDIS_HOST || '127.0.0.1',
    port: Number(process.env.REDIS_PORT || '6379'),
    lazyConnect: false,
    maxRetriesPerRequest: 3,
    enableReadyCheck: true
});

redis.on('error', (err) => {
    console.error('[redis] connection error', err?.message || err);
});

redis.on('connect', () => {
    console.log('[redis] connected');
});

redis.on('ready', () => {
    console.log('[redis] ready');
});

export default redis;
