import Foundation
import Cognition

/// Current weather + short-term forecast via Open-Meteo (free, no
/// key, no rate limit at our usage level). The LLM passes a
/// human-readable location ("Manchester", "Tokyo", "37.78,-122.42")
/// and gets back temperature, conditions, wind, plus the next 24
/// hours of hourly forecasts.
///
/// We deliberately don't auto-detect location via CoreLocation in
/// this iteration — that would introduce another TCC permission
/// prompt and most "what's the weather?" questions name the place
/// anyway. If the user asks "what's it like outside?" without a
/// location, the LLM should ask for one or pull it from memory
/// (e.g. a `remember`-stored home city).
enum WeatherTool {
    private static let geocodeURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search")!
    private static let forecastURL = URL(string: "https://api.open-meteo.com/v1/forecast")!

    static func register(in registry: ToolRegistry, urlSession: URLSession = .shared) async {
        await registry.register(
            name: "get_weather",
            description: "Get current weather and a short forecast. With no `location` argument the Mac's current location is used (subject to system Location permission). Otherwise pass a city/place name (\"Manchester\") or a literal lat,lon (\"40.7,-74.0\"). Returns temperature in Celsius, plain-English conditions, wind speed, humidity, and the next 24 hourly forecasts.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "location": .object([
                        "type": .string("string"),
                        "description": .string("Optional city name, place name, or 'lat,lon'. Omit for the Mac's current location."),
                    ]),
                ]),
            ]),
            handler: { args in
                let raw = args.asObject?["location"]?.asString?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if raw.isEmpty {
                    return await fetchHere(session: urlSession)
                }
                return await fetch(location: raw, session: urlSession)
            }
        )
    }

    /// One-shot CoreLocation fix → forecast. Used when the LLM omits
    /// the `location` argument. Falls back to a clear "permission
    /// denied" error if the user hasn't granted Location yet.
    private static func fetchHere(session: URLSession) async -> JSONValue {
        do {
            let loc = try await MainActor.run {
                LocationProvider.shared
            }.currentLocation()
            let lat = loc.coordinate.latitude
            let lon = loc.coordinate.longitude
            return try await forecast(
                lat: lat, lon: lon,
                name: String(format: "%.3f,%.3f", lat, lon),
                session: session
            )
        } catch {
            return .object(["error": .string("\(error)")])
        }
    }

    private static func fetch(location: String, session: URLSession) async -> JSONValue {
        let coords: (lat: Double, lon: Double, name: String)
        do {
            coords = try await resolve(location: location, session: session)
        } catch {
            return .object(["error": .string("\(error)")])
        }
        do {
            return try await forecast(
                lat: coords.lat, lon: coords.lon,
                name: coords.name, session: session
            )
        } catch {
            return .object(["error": .string("forecast failed: \(error)")])
        }
    }

    /// Accept either `"lat,lon"` (skip geocoding) or a place name
    /// (round-trip through Open-Meteo's geocoding API).
    private static func resolve(
        location: String, session: URLSession
    ) async throws -> (lat: Double, lon: Double, name: String) {
        let parts = location.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 2,
           let lat = Double(parts[0]),
           let lon = Double(parts[1]) {
            return (lat, lon, location)
        }

        var c = URLComponents(url: geocodeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "name", value: location),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, response) = try await session.data(from: c.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WeatherError.geocodeFailed(location: location)
        }
        struct Geo: Decodable {
            struct Result: Decodable {
                let name: String?
                let country: String?
                let latitude: Double
                let longitude: Double
            }
            let results: [Result]?
        }
        let decoded = try JSONDecoder().decode(Geo.self, from: data)
        guard let first = decoded.results?.first else {
            throw WeatherError.notFound(location: location)
        }
        let displayName = [first.name, first.country].compactMap { $0 }.joined(separator: ", ")
        return (first.latitude, first.longitude, displayName)
    }

    /// One-shot forecast call — current conditions + 24 hourly slots.
    /// Open-Meteo returns weather codes; we map to plain English so
    /// the LLM doesn't have to memorise the WMO table.
    private static func forecast(
        lat: Double, lon: Double, name: String, session: URLSession
    ) async throws -> JSONValue {
        var c = URLComponents(url: forecastURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current",
                         value: "temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m,is_day"),
            URLQueryItem(name: "hourly",
                         value: "temperature_2m,weather_code"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
        ]
        let (data, _) = try await session.data(from: c.url!)
        struct Forecast: Decodable {
            struct Current: Decodable {
                let time: String
                let temperature_2m: Double
                let weather_code: Int
                let wind_speed_10m: Double
                let relative_humidity_2m: Int
                let is_day: Int
            }
            struct Hourly: Decodable {
                let time: [String]
                let temperature_2m: [Double]
                let weather_code: [Int]
            }
            let timezone: String?
            let current: Current?
            let hourly: Hourly?
        }
        let decoded = try JSONDecoder().decode(Forecast.self, from: data)
        guard let cur = decoded.current else {
            throw WeatherError.emptyForecast
        }

        // Hourly: from `now` forward, capped at the next 24 entries.
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        let now = Date()
        var hourly: [JSONValue] = []
        if let h = decoded.hourly {
            // Open-Meteo time strings are local without offset
            // ("2026-05-08T13:00") — parse with the matching formatter.
            let hourFmt = DateFormatter()
            hourFmt.locale = Locale(identifier: "en_US_POSIX")
            hourFmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
            hourFmt.timeZone = TimeZone(identifier: decoded.timezone ?? "UTC")
            for i in 0..<min(h.time.count, h.temperature_2m.count, h.weather_code.count) {
                guard let parsed = hourFmt.date(from: h.time[i]),
                      parsed > now,
                      hourly.count < 24 else { continue }
                hourly.append(.object([
                    "time":       .string(isoFmt.string(from: parsed)),
                    "temp_c":     .number(h.temperature_2m[i]),
                    "conditions": .string(describe(code: h.weather_code[i])),
                ]))
            }
        }

        return .object([
            "location":   .string(name),
            "temp_c":     .number(cur.temperature_2m),
            "conditions": .string(describe(code: cur.weather_code)),
            "wind_kph":   .number(cur.wind_speed_10m),
            "humidity":   .number(Double(cur.relative_humidity_2m)),
            "is_day":     .bool(cur.is_day == 1),
            "timezone":   .string(decoded.timezone ?? ""),
            "hourly":     .array(hourly),
        ])
    }

    /// WMO weather codes → plain English. Source: open-meteo.com docs.
    /// Only the buckets that humans actually distinguish — "freezing
    /// rain" and "moderate freezing rain" both round to "freezing rain"
    /// because the LLM doesn't need that resolution.
    static func describe(code: Int) -> String {
        switch code {
        case 0:        return "clear"
        case 1:        return "mainly clear"
        case 2:        return "partly cloudy"
        case 3:        return "overcast"
        case 45, 48:   return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57:   return "freezing drizzle"
        case 61, 63, 65: return "rain"
        case 66, 67:   return "freezing rain"
        case 71, 73, 75: return "snow"
        case 77:       return "snow grains"
        case 80, 81, 82: return "rain showers"
        case 85, 86:   return "snow showers"
        case 95:       return "thunderstorm"
        case 96, 99:   return "thunderstorm with hail"
        default:       return "code \(code)"
        }
    }
}

enum WeatherError: Error, CustomStringConvertible {
    case geocodeFailed(location: String)
    case notFound(location: String)
    case emptyForecast

    var description: String {
        switch self {
        case .geocodeFailed(let l): return "Could not geocode '\(l)'"
        case .notFound(let l):      return "Place not found: '\(l)'"
        case .emptyForecast:        return "Open-Meteo returned no current data"
        }
    }
}
