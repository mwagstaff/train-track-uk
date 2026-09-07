import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const defaultConfigPath = fileURLToPath(
    new URL('../resources/operator-branding.json', import.meta.url)
);
const cacheTtlMs = 5 * 60 * 1000;
const hexColorPattern = /^#[0-9A-Fa-f]{6}$/;

let cachedConfig = null;
let cacheExpiresAt = 0;

function configuredPath() {
    return process.env.OPERATOR_BRANDING_CONFIG_PATH
        ? path.resolve(process.env.OPERATOR_BRANDING_CONFIG_PATH)
        : defaultConfigPath;
}

export function loadOperatorBrandingConfig(configPath = configuredPath()) {
    const parsed = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    if (!parsed.version || !Array.isArray(parsed.operators) || parsed.operators.length === 0) {
        throw new Error('operator branding config requires a version and operators');
    }

    const names = new Set();
    for (const operator of parsed.operators) {
        if (!operator?.name || !hexColorPattern.test(operator.color_hex || '')) {
            throw new Error('each operator requires a name and six-digit color_hex');
        }
        const normalizedName = operator.name.trim().toLowerCase();
        if (names.has(normalizedName)) {
            throw new Error(`duplicate operator name: ${operator.name}`);
        }
        names.add(normalizedName);
        if (!Array.isArray(operator.operator_codes) || !Array.isArray(operator.aliases)) {
            throw new Error(`operator_codes and aliases must be arrays for ${operator.name}`);
        }
    }

    return parsed;
}

export function getOperatorBrandingConfig() {
    const now = Date.now();
    if (cachedConfig && now < cacheExpiresAt) {
        return cachedConfig;
    }

    try {
        cachedConfig = loadOperatorBrandingConfig();
    } catch (error) {
        if (!cachedConfig) {
            throw error;
        }
        console.error('[operator-branding] Failed to refresh config:', error?.message || error);
    }
    cacheExpiresAt = now + cacheTtlMs;
    return cachedConfig;
}
