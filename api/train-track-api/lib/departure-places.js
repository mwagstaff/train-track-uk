export function primaryPlace(value) {
    if (Array.isArray(value)) {
        return value[0] || null;
    }
    return value || null;
}
