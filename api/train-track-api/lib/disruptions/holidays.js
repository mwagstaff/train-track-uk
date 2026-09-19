// The union is deliberately conservative: without a complete route geography,
// a regional bank holiday is unsuitable as a normal weekday comparison.
export class BankHolidayCalendar {
    constructor({ fetchImpl = fetch, now = Date.now } = {}) { this.fetch = fetchImpl; this.now = now; this.snapshot = null; this.lastAttempt = 0; }
    async refresh() {
        if (this.now() - this.lastAttempt < 86400000) return;
        this.lastAttempt = this.now();
        try {
            const response = await this.fetch('https://www.gov.uk/bank-holidays.json', { signal: AbortSignal.timeout(5000), redirect: 'error' });
            if (!response.ok) return;
            const text = await response.text();
            if (text.length > 500000) return;
            const body = JSON.parse(text), dates = new Set(), years = new Set();
            for (const region of ['england-and-wales', 'scotland', 'northern-ireland']) {
                if (!Array.isArray(body[region]?.events) || !body[region].events.length) return;
                for (const event of body[region].events) {
                    if (!/^\d{4}-\d{2}-\d{2}$/.test(event.date)) return;
                    dates.add(event.date); years.add(event.date.slice(0, 4));
                }
            }
            this.snapshot = { dates, years, checkedAt: this.now() };
        } catch { /* Unknown calendar suppresses comparisons, not official notices. */ }
    }
    ordinary(date) {
        return Boolean(this.snapshot && this.now() - this.snapshot.checkedAt < 7 * 86400000
            && this.snapshot.years.has(date.slice(0, 4)) && !this.snapshot.dates.has(date));
    }
}
