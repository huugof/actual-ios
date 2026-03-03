import Foundation

enum AppPaths {
    static func databasePath() throws -> String {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ActualCompanion", isDirectory: true)

        let basePath = baseURL.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: basePath) {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }

        return baseURL
            .appendingPathComponent("app.sqlite", isDirectory: false)
            .path(percentEncoded: false)
    }
}
