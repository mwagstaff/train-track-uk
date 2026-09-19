/** A shared hub or a union of unrelated affected services is not route
 * evidence. Prefer missing an uncertain match to warning for another branch. */
export function noticeAffectsJourney(notice, stations) {
    if (notice?.planned !== true || !Array.isArray(stations) || stations.length < 2
        || stations.some(station => typeof station !== 'string')) return false;
    if (Array.isArray(notice.closedStationCRS) && stations.some(station => notice.closedStationCRS.includes(station))) return true;
    return Array.isArray(notice.affectedStationClauses) && notice.affectedStationClauses.some(clause =>
        Array.isArray(clause) && stations.every(station => clause.includes(station)));
}
export const ENGINEERING_RELEVANCE_VERSION = 1;
