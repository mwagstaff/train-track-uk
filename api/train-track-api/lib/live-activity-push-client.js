import fs from 'fs';
import path from 'path';
import http2 from 'http2';
import crypto from 'crypto';

// Helper to build base64url strings without pulling in extra deps
function base64UrlEncode(input) {
    const buffer = Buffer.isBuffer(input) ? input : Buffer.from(input);
    return buffer.toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
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

        // Use per-request useSandbox if provided, otherwise default to production (false)
        // This ensures older clients that don't send use_sandbox will use production APNs
        const useSandbox = options.useSandbox === true;
        const host = useSandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
        const session = http2.connect(`https://${host}`);
        const jwt = this.buildJwt();
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

        if (this.isLoggingEnabled()) {
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

        return await new Promise((resolve) => {
            let status;
            let responseBody = '';

            const request = session.request(headers);

            request.setEncoding('utf8');

            request.on('response', (headers) => {
                status = headers[':status'];
            });

            request.on('data', (chunk) => {
                responseBody += chunk;
            });

            request.on('end', () => {
                session.close();
                const parsedBody = this.safeParseJson(responseBody);

                // Check for APNs error conditions
                const isError = status >= 400;
                const isBadToken = status === 410 || parsedBody?.reason === 'BadDeviceToken' || parsedBody?.reason === 'Unregistered';

                if (this.isLoggingEnabled()) {
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
                    bytesSent: body.length,
                    isError,
                    isBadToken
                });
            });

            request.on('error', (error) => {
                session.close();
                console.error(`APNS live activity push failed: ${error?.message || error}`);
                resolve({ status: 'error', error: error?.message || error.toString() });
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
