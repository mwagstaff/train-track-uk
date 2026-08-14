export function minutesUntilDeparture(timeString, nowMinutes) {
    if (typeof timeString !== 'string') return null;

    const parts = timeString.split(':');
    if (parts.length !== 2) return null;

    const hours = Number(parts[0]);
    const minutes = Number(parts[1]);
    if (!Number.isInteger(hours) || !Number.isInteger(minutes)) return null;

    const difference = hours * 60 + minutes - nowMinutes;
    return difference < -720 ? difference + 1440 : difference;
}
