import Foundation

// Client-side tool executors for the app-side agent loop (prompt-based tool
// calling on a raw model — no server pipe, no native function calling). Web
// search goes through Open WebUI's own configured search engine so it works on
// any instance; weather uses the free public Open-Meteo API.

/// One web-search hit.
public struct OWWebResult: Sendable {
    public var title: String
    public var url: String
    public var snippet: String
}

/// The outcome of running one tool: text to feed back to the model, plus sources
/// for the auditable tool card.
public struct OWToolResult: Sendable {
    public var text: String
    public var sources: [OWSource]
    public init(text: String, sources: [OWSource] = []) { self.text = text; self.sources = sources }
}

extension OpenWebUIClient {
    /// Runs a web search through Open WebUI's configured engine (whatever the
    /// instance uses — SearXNG, Google, Brave, …) and returns clean title/url/
    /// snippet results. POST /api/v1/retrieval/process/web/search returns an
    /// `items` array regardless of the server's embedding/RAG settings.
    public func webSearch(_ query: String, max: Int = 6) async throws -> [OWWebResult] {
        let req = try jsonRequest("/api/v1/retrieval/process/web/search",
                                  method: "POST", body: ["queries": [query]])
        let data = try await send(req, long: true)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return [] }
        return items.prefix(max).compactMap { it in
            let url = (it["link"] as? String) ?? (it["url"] as? String) ?? ""
            guard !url.isEmpty else { return nil }
            return OWWebResult(title: (it["title"] as? String) ?? url,
                               url: url,
                               snippet: (it["snippet"] as? String) ?? "")
        }
    }

    /// web_search tool → text for the model + sources for the card.
    public func runWebSearchTool(query: String) async -> OWToolResult {
        do {
            let hits = try await webSearch(query)
            if hits.isEmpty { return OWToolResult(text: "[web_search: no results]") }
            let text = "Search results for '\(query)':\n" + hits.enumerated().map { i, h in
                "\n[\(i + 1)] \(h.title)\n    \(h.url)\n    \(h.snippet.prefix(400))"
            }.joined()
            let sources = hits.map { OWSource(title: $0.title.isEmpty ? $0.url : $0.title, url: $0.url) }
            return OWToolResult(text: text, sources: sources)
        } catch {
            return OWToolResult(text: "[web_search error: \(error.localizedDescription)]")
        }
    }
}

/// weather tool → current conditions via Open-Meteo (public, no key). Free
/// function since it needs no server auth.
public func runWeatherTool(location: String, fahrenheit: Bool = true) async -> OWToolResult {
    let deg = fahrenheit ? "°F" : "°C"
    let unit = fahrenheit ? "fahrenheit" : "celsius"
    let windUnit = fahrenheit ? "mph" : "kmh"
    func get(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    // Open-Meteo's geocoder wants a bare place name — "Cambridge, MA" returns
    // nothing. Try the full string, then progressively simpler forms (drop the
    // state/country after a comma) so "City, ST" and "City, Country" both resolve.
    func geocode(_ q: String) async -> [String: Any]? {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        guard let geo = await get("https://geocoding-api.open-meteo.com/v1/search?name=\(enc)&count=1"),
              let hit = (geo["results"] as? [[String: Any]])?.first,
              hit["latitude"] is Double, hit["longitude"] is Double else { return nil }
        return hit
    }
    var candidates = [location]
    if let head = location.split(separator: ",").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
       head != location { candidates.append(head) }
    var found: [String: Any]?
    for c in candidates { if let h = await geocode(c) { found = h; break } }
    guard let hit = found, let lat = hit["latitude"] as? Double, let lon = hit["longitude"] as? Double else {
        return OWToolResult(text: "[weather: could not find '\(location)']")
    }
    let place = [hit["name"] as? String, hit["admin1"] as? String, hit["country"] as? String]
        .compactMap { $0 }.joined(separator: ", ")
    let fURL = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)" +
        "&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m" +
        "&daily=temperature_2m_max,temperature_2m_min&temperature_unit=\(unit)&wind_speed_unit=\(windUnit)" +
        "&timezone=auto&forecast_days=1"
    guard let f = await get(fURL), let cur = f["current"] as? [String: Any] else {
        return OWToolResult(text: "[weather: lookup failed for '\(place)']")
    }
    let codes: [Int: String] = [0: "clear sky", 1: "mainly clear", 2: "partly cloudy", 3: "overcast",
        45: "fog", 48: "rime fog", 51: "light drizzle", 53: "drizzle", 55: "dense drizzle",
        61: "light rain", 63: "rain", 65: "heavy rain", 71: "light snow", 73: "snow", 75: "heavy snow",
        80: "rain showers", 81: "rain showers", 82: "violent rain showers", 95: "thunderstorm",
        96: "thunderstorm w/ hail", 99: "thunderstorm w/ heavy hail"]
    let cond = codes[(cur["weather_code"] as? Int) ?? -1] ?? "unknown conditions"
    let daily = f["daily"] as? [String: Any]
    let hi = (daily?["temperature_2m_max"] as? [Double])?.first
    let lo = (daily?["temperature_2m_min"] as? [Double])?.first
    func s(_ k: String) -> String { cur[k].map { "\($0)" } ?? "?" }
    let text = "Current weather in \(place): \(s("temperature_2m"))\(deg) " +
        "(feels like \(s("apparent_temperature"))\(deg)), \(cond). " +
        "Humidity \(s("relative_humidity_2m"))%, wind \(s("wind_speed_10m")) \(windUnit). " +
        (hi != nil && lo != nil ? "Today: \(lo!)\(deg)–\(hi!)\(deg)." : "")
    return OWToolResult(text: text)
}
