import fs from 'fs';
import path from 'path';
import http2 from 'http2';
import crypto from 'crypto';
import {
    recordPushNotification,
    recordPushRetry,
    recordPushRetryExhausted
} from './metrics.js';
import {
    computeExponentialBackoffMs,
    isRetryableHttpStatus,
    parseRetryAfterMs,
    sleep
} from './retry-utils.js';

const DEFAULT_PUSH_MAX_RETRIES = Number(process.env.APNS_PUSH_MAX_RETRIES || '3');
const DEFAULT_PUSH_RETRY_BASE_DELAY_MS = Number(process.env.APNS_PUSH_RETRY_BASE_DELAY_MS || '400');
const DEFAULT_PUSH_RETRY_MAX_DELAY_MS = Number(process.env.APNS_PUSH_RETRY_MAX_DELAY_MS || '12000');

function base64UrlEncode(input) {
    const buffer = Buffer.isBuffer(input) ? input : Buffer.from(input);
    return buffer.toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function retryReason(status) {
    if (typeof status === 'number') {
        return `http_${status}`;
    }
    return 'network_error';
}

export class LiveActivityPushClient {
    constructor(options = {}) {
        this.keyId = options.keyId || process.env.APNS_KEY_ID;
        this.teamId = options.teamId || process.env.APNS_TEAM_ID;
        this.topic = options.topic || process.env.APNS_LIVE_ACTIVITY_TOPIC || 'dev.skynolimit.traintrack.push-type.liveactivity';
        const sandboxFlag = process.env.APNS_USE_SANDBOX;
        this.useSandbox = typeof sandboxFlag === 'string' ? sandboxFlag.toLowerCase() !== 'false' : false;
        this.privateKey = options.privateKey || this.loadPrivateKey(options.keyPath);
    }

    isLoggingEnabled() {
        const flag = process.env.DEBUG_CONSOLE_LOGGING_APNS;
        return typeof flag === 'string' && flag.toLowerCase() === 'true';
    }

    maskToken(token) {
        if (!token || typeof token !== 'string') return token;
        if (token.length <= 10) return `${token.slice(0, 3)}***`;
        return `${token.slice(0, 6)}...${token.slice(-4)}`;
    }

    loadPrivateKey(customPath) {
        if (process.env.APNS_AUTH_KEY) {
            return process.env.APNS_AUTH_KEY.replace(/\\n/g, '\n');
        }

        const fallbackPath = path.join(process.cwd(), 'certs', 'APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8');
        const keyPath = customPath || process.env.APNS_AUTH_KEY_PATH || fallbackPath;
        if (fs.existsSync(keyPath)) {
            return fs.readFileSync(keyPath, 'utf8');
        }
        return null;
    }

    isConfigured() {
        return Boolean(this.keyId && this.teamId && this.topic && this.privateKey);
    }

    buildJwt() {
        if (!this.isConfigured()) {
            throw new Error('APNS credentials are not configured');
        }

        const header = {
            alg: 'ES256',
            kid: this.keyId,
            typ: 'JWT'
        };
        const payload = {
            iss: this.teamId,
            iat: Math.floor(Date.now() / 1000)
        };

        const headerEncoded = base64UrlEncode(JSON.stringify(header));
        const payloadEncoded = base64UrlEncode(JSON.stringify(payload));
        const signingInput = `${headerEncoded}.${payloadEncoded}`;

        const signer = crypto.createSign('sha256');
        signer.update(signingInput);
        signer.end();
        const signature = signer.sign(this.privateKey);
        const signatureEncoded = base64UrlEncode(signature);

        return `${signingInput}.${signatureEncoded}`;
    }

    async sendLiveActivityUpdate(deviceToken, payload, options = {}) {
        if (!deviceToken) {
            throw new Error('Missing device token for live activity update');
        }

        if (!this.isConfigured()) {
            console.warn('APNS credentials missing; skipping live activity push send');
            return { skipped: true, reason: 'apns_not_configured', payload };
        }

        // Use per-request useSandbox if provided, otherwise default to production.
        const useSandbox = options.useSandbox === true;
        const environment = useSandbox ? 'sandbox' : 'prod';
        const host = useSandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
        const event = typeof options.event === 'string' && options.event.length > 0
            ? options.event
            : 'live_activity_update';

        const maxRetries = Number.isFinite(DEFAULT_PUSH_MAX_RETRIES) && DEFAULT_PUSH_MAX_RETRIES >= 0
            ? Math.trunc(DEFAULT_PUSH_MAX_RETRIES)
            : 3;

        let attempt = 0;
        while (attempt <= maxRetries) {
            const result = await this.sendSingleRequest({
                host,
                deviceToken,
                payload,
                jwt: this.buildJwt(),
                logEnabled: this.isLoggingEnabled()
            });

            recordPushNotification({
                channel: 'live_activity',
                event,
                environment,
                status: result?.status,
                durationMs: result?.durationMs
            });

            const shouldRetry = !result?.isBadToken && (
                result?.status === 'error' || isRetryableHttpStatus(result?.status)
            );

            if (!shouldRetry) {
                return result;
            }

            if (attempt >= maxRetries) {
                recordPushRetryExhausted({
                    channel: 'live_activity',
                    event,
                    environment,
                    reason: retryReason(result?.status),
                    status: result?.status
                });
                return result;
            }

            const retryAfterMs = parseRetryAfterMs(result?.headers?.['retry-after']);
            const backoffMs = computeExponentialBackoffMs({
                attemptNumber: attempt + 1,
                baseDelayMs: DEFAULT_PUSH_RETRY_BASE_DELAY_MS,
                maxDelayMs: DEFAULT_PUSH_RETRY_MAX_DELAY_MS,
                retryAfterMs
            });

            recordPushRetry({
                channel: 'live_activity',
                event,
                environment,
                reason: retryReason(result?.status),
                status: result?.status,
                backoffMs
            });

            if (this.isLoggingEnabled()) {
                console.log('[live-activity] apns_retry', JSON.stringify({
                    host,
                    event,
                    attempt: attempt + 1,
                    backoffMs,
                    status: result?.status,
                    reason: retryReason(result?.status),
                    token: this.maskToken(deviceToken)
                }));
            }

            await sleep(backoffMs);
            attempt += 1;
        }

        throw new Error('APNS live-activity retry loop exited unexpectedly');
    }

    async sendSingleRequest({ host, deviceToken, payload, jwt, logEnabled }) {
        const session = http2.connect(`https://${host}`);
        const body = JSON.stringify(payload);
        const headers = {
            ':method': 'POST',
            ':path': `/3/device/${deviceToken}`,
            'apns-topic': this.topic,
            'apns-push-type': 'liveactivity',
            'apns-priority': '10',
            authorization: `bearer ${jwt}`,
            'content-type': 'application/json'
        };

        if (logEnabled) {
            console.log(
                '[live-activity] apns_request_headers',
                JSON.stringify({
                    host,
                    headers: {
                        'apns-topic': headers['apns-topic'],
                        'apns-push-type': headers['apns-push-type'],
                        'apns-priority': headers['apns-priority'],
                        authorization: 'bearer ...',
                        'content-type': headers['content-type']
                    },
                    token: this.maskToken(deviceToken)
                })
            );
        }

        const startedAt = Date.now();

        return await new Promise((resolve) => {
            let status;
            let responseBody = '';
            let responseHeaders = {};

            const request = session.request(headers);
            request.setEncoding('utf8');

            request.on('response', (incomingHeaders) => {
                responseHeaders = incomingHeaders || {};
                status = incomingHeaders?.[':status'];
            });

            request.on('data', (chunk) => {
                responseBody += chunk;
            });

            request.on('end', () => {
                session.close();
                const parsedBody = this.safeParseJson(responseBody);
                const isError = typeof status === 'number' && status >= 400;
                const isBadToken = status === 410 || parsedBody?.reason === 'BadDeviceToken' || parsedBody?.reason === 'Unregistered';

                if (logEnabled) {
                    console.log(
                        '[live-activity] apns_response',
                        JSON.stringify({
                            host,
                            topic: headers['apns-topic'],
                            status,
                            body: parsedBody,
                            token: this.maskToken(deviceToken),
                            isError,
                            isBadToken
                        })
                    );
                }

                if (isBadToken) {
                    console.warn(`⚠️ [APNs] Bad/expired device token detected (status ${status}): ${this.maskToken(deviceToken)} - reason: ${parsedBody?.reason || 'unknown'}`);
                }

                resolve({
                    status,
                    body: parsedBody,
                    headers: responseHeaders,
                    bytesSent: body.length,
                    isError,
                    isBadToken,
                    durationMs: Date.now() - startedAt
                });
            });

            request.on('error', (error) => {
                session.close();
                console.error(`APNS live activity push failed: ${error?.message || error}`);
                resolve({
                    status: 'error',
                    error: error?.message || error.toString(),
                    headers: {},
                    isBadToken: false,
                    durationMs: Date.now() - startedAt
                });
            });

            request.write(body);
            request.end();
        });
    }

    safeParseJson(input) {
        try {
            if (!input) return {};
            return JSON.parse(input);
        } catch (error) {
            return { raw: input, parseError: error?.message || 'Failed to parse APNS response JSON' };
        }
    }
}
