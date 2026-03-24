import Foundation

enum DeepLinkBuilder {
    static func journeyURL(from fromCRS: String, to toCRS: String, activateUpdates: Bool = false) -> URL? {
        var comps = URLComponents()
        comps.scheme = "traintrack"
        comps.host = "journey"
        var queryItems = [
            URLQueryItem(name: "from", value: fromCRS),
            URLQueryItem(name: "to", value: toCRS)
        ]
        if activateUpdates {
            queryItems.append(URLQueryItem(name: "activate_updates", value: "1"))
        }
        comps.queryItems = queryItems
        return comps.url
    }
}
