import Foundation

enum DeepLinkBuilder {
    static func journeyURL(from fromCRS: String, to toCRS: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "traintrack"
        comps.host = "journey"
        comps.queryItems = [
            URLQueryItem(name: "from", value: fromCRS),
            URLQueryItem(name: "to", value: toCRS)
        ]
        return comps.url
    }
}

