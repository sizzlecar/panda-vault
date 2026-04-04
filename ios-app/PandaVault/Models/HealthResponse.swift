import Foundation

struct HealthResponse: Codable {
    let status: String
    let version: String?
    let storageRoot: String?
}
