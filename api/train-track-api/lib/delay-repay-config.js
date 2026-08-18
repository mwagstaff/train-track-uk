import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const defaultConfigPath = fileURLToPath(
    new URL('../resources/delay-repay-operators.json', import.meta.url)
);
const cacheTtlMs = 5 * 60 * 1000;

let cachedConfig = null;
let cacheExpiresAt = 0;

function normalize(value) {
    return typeof value === 'string'
        ? value.trim().toLowerCase().replace(/[^a-z0-9]/g, '')
        : '';
}

function loadConfig() {
    const now = Date.now();
    if (cachedConfig && now < cacheExpiresAt) {
        return cachedConfig;
    }

    const configPath = process.env.DELAY_REPAY_CONFIG_PATH
        ? path.resolve(process.env.DELAY_REPAY_CONFIG_PATH)
        : defaultConfigPath;

    try {
        const parsed = JSON.parse(fs.readFileSync(configPath, 'utf8'));
        if (!Array.isArray(parsed.operators)) {
            throw new Error('operators must be an array');
        }

        const byName = new Map();
        const byCode = new Map();
        for (const operator of parsed.operators) {
            if (!operator?.name || !operator?.claim_url) {
                throw new Error('each operator requires name and claim_url');
            }
            const url = new URL(operator.claim_url);
            if (url.protocol !== 'https:') {
                throw new Error(`claim_url for ${operator.name} must use HTTPS`);
            }
            for (const alias of [operator.name, ...(operator.aliases || [])]) {
                byName.set(normalize(alias), operator);
            }
            for (const code of operator.operator_codes || []) {
                const normalizedCode = normalize(code);
                if (!byCode.has(normalizedCode)) {
                    byCode.set(normalizedCode, operator);
                }
            }
        }

        cachedConfig = {
            version: parsed.version || null,
            sourceUrl: parsed.source_url || null,
            byName,
            byCode
        };
        cacheExpiresAt = now + cacheTtlMs;
    } catch (error) {
        if (!cachedConfig) {
            throw error;
        }
        console.error('[delay-repay] Failed to refresh operator config:', error?.message || error);
        cacheExpiresAt = now + cacheTtlMs;
    }

    return cachedConfig;
}

export function resolveDelayRepayOperator({ operatorCode, operatorName }) {
    const config = loadConfig();
    const operator = config.byName.get(normalize(operatorName))
        || config.byCode.get(normalize(operatorCode));
    if (!operator) {
        return null;
    }
    return {
        name: operator.name,
        operator_code: operator.operator_codes?.[0] || null,
        claim_url: operator.claim_url,
        config_version: config.version
    };
}
