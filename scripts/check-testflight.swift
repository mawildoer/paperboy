// Read-only App Store Connect validation. The private key is never printed.
import CryptoKit
import Foundation

struct ValidationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Attributes: Decodable, Sendable {
    let name: String?
    let version: String?
    let processingState: String?
    let internalBuildState: String?
    let externalBuildState: String?
    let expired: Bool?
}

struct Resource: Decodable, Sendable {
    let id: String
    let attributes: Attributes?
}

struct Response<Value: Decodable & Sendable>: Decodable, Sendable {
    let data: Value
}

func encoded(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func report(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

@MainActor
final class AppleClient {
    let key: P256.Signing.PrivateKey
    let keyID: String
    let issuerID: String

    init(path: String, keyID: String, issuerID: String) throws {
        key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: path, encoding: .utf8))
        self.keyID = keyID
        self.issuerID = issuerID
    }

    func get<Value: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        let now = Int(Date().timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
        let claims = try JSONSerialization.data(withJSONObject: [
            "iss": issuerID, "iat": now, "exp": now + 300, "aud": "appstoreconnect-v1",
        ])
        let message = encoded(header) + "." + encoded(claims)
        let signature = try key.signature(for: Data(message.utf8))
        let token = message + "." + encoded(signature.rawRepresentation)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.appstoreconnect.apple.com"
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ValidationError("Invalid Apple API URL") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ValidationError("Apple status lookup failed (HTTP \(status)); check API role and app access")
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

guard CommandLine.arguments.count == 5 else {
    throw ValidationError("Usage: swift check-testflight.swift KEY_PATH KEY_ID ISSUER_ID BUILD_NUMBER")
}
let args = CommandLine.arguments
let client = try AppleClient(path: args[1], keyID: args[2], issuerID: args[3])
let buildNumber = args[4]
let apps: Response<[Resource]> = try await client.get("/v1/apps", query: [
    URLQueryItem(name: "filter[bundleId]", value: "app.paperboy.readerc67aad"),
])
guard apps.data.count == 1, let app = apps.data.first else {
    throw ValidationError("Expected one Paperboy app record for app.paperboy.readerc67aad")
}
let deadline = Date().addingTimeInterval(20 * 60)
var processed: Resource?
while Date() < deadline {
    let builds: Response<[Resource]> = try await client.get("/v1/builds", query: [
        URLQueryItem(name: "filter[app]", value: app.id),
        URLQueryItem(name: "filter[version]", value: buildNumber),
        URLQueryItem(name: "limit", value: "10"),
    ])
    guard builds.data.count <= 1 else { throw ValidationError("Ambiguous Paperboy build number \(buildNumber)") }
    if let build = builds.data.first {
        let state = build.attributes?.processingState ?? "UNKNOWN"
        report("Paperboy build \(buildNumber): \(state)")
        if state == "FAILED" || state == "INVALID" || build.attributes?.expired == true {
            throw ValidationError("Apple rejected or expired build \(buildNumber): \(state)")
        }
        if state == "VALID" { processed = build; break }
    } else {
        report("Waiting for Paperboy build \(buildNumber) to appear in App Store Connect")
    }
    try await Task.sleep(for: .seconds(30))
}
guard let build = processed else {
    throw ValidationError("Apple processing was not confirmed within 20 minutes; rerun status validation without uploading again")
}
let beta: Response<Resource> = try await client.get("/v1/builds/\(build.id)/buildBetaDetail")
let internalState = beta.data.attributes?.internalBuildState ?? "UNKNOWN"
let externalState = beta.data.attributes?.externalBuildState ?? "UNKNOWN"
let link = "https://appstoreconnect.apple.com/apps/\(app.id)/testflight"
report("TestFlight internal state: \(internalState); external state: \(externalState)")
report("App Store Connect: \(link)")
guard ["READY_FOR_BETA_TESTING", "IN_BETA_TESTING"].contains(internalState) else {
    throw ValidationError("Build is processed, but internal TestFlight status requires attention: \(internalState)")
}
if let summary = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"],
   let file = FileHandle(forWritingAtPath: summary) {
    defer { try? file.close() }
    try file.seekToEnd()
    try file.write(contentsOf: Data("\nValidated **Paperboy \(buildNumber)**: Apple processing **VALID**, internal TestFlight **\(internalState)**. [Open TestFlight](\(link)).\n".utf8))
}
report("PASS: Apple processed Paperboy build \(buildNumber) and it is ready for configured internal testers")
