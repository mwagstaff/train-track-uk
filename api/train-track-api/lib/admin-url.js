import path from 'node:path';

// A relative URL keeps any public prefix that a reverse proxy removes before
// forwarding the request. Use the internal request path, without host headers.
export function createAdminUrl(requestPath = '/admin') {
    const pathname = requestPath.split(/[?#]/, 1)[0];
    const directory = pathname.endsWith('/') ? pathname : path.posix.dirname(pathname);
    return target => {
        if (!target.startsWith('/') || target.startsWith('//')) return target;
        const [, destination, suffix] = target.match(/^([^?#]*)(.*)$/);
        if (destination.endsWith('/')) {
            return `${path.posix.relative(directory, destination) || '.'}/${suffix}`;
        }
        // Resolve the containing directory separately so a destination such as
        // /admin stays /admin, rather than acquiring a trailing slash via "..".
        const parent = path.posix.relative(directory, path.posix.dirname(destination));
        return `${parent || '.'}/${path.posix.basename(destination)}${suffix}`;
    };
}
