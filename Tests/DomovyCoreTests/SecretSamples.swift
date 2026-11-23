import DomovyCore
import Foundation

/// Obviously fake values that still match the rules. Each is assembled from pieces, so no
/// token-shaped literal sits in the source for push protection or real scanners to trip on.
enum SecretSamples {
    static let aws = "AKIA" + "EXAMPLEFAKE00001"
    static let github = "ghp" + "_" + String(repeating: "FAKEfake", count: 4) + "0000"
    static let githubPAT = "github" + "_pat_" + "11FAKEFAKE0000000000_" + String(repeating: "fake", count: 12)
    static let anthropic = "sk-" + "ant-" + "api03-" + String(repeating: "FAKEfake0123456789", count: 3) + "a1B2"
    static let openAI = "sk-" + "proj-" + "FAKEa1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuV"
    static let slack = "xox" + "b-" + "FAKE-0000-fake-token"
    static let slackWebhook = "https://hooks.slack.com/services/" + "TFAKE0000/BFAKE0000/" + "fakefakefakefake"
    static let stripe = "sk_" + "test_" + "FAKEfakeFAKEfake0000"
    static let google = "AI" + "za" + "FAKE-fake_FAKE-fake_FAKE-fake_00000"
    static let jwt = "eyJ" + "hbGciOiJIUzI1NiJ9" + "." + "eyJ" + "zdWIiOiJmYWtlLXVzZXIifQ" + "." + "FAKEsignatureFAKEsignature0000"
    static let privateKey = "-----BEGIN " + "RSA PRIVATE KEY-----\nFAKEKEYDATAFAKEKEYDATA0000\nFAKEKEYDATA==\n-----END RSA PRIVATE KEY-----"
    static let password = "Zq8vN3xLm2Pw7Rt"

    /// Rule id, the text placed in a message, and the exact value that rule must find.
    static let cases: [(rule: String, text: String, value: String)] = [
        ("aws-access-key", "my key is \(aws) for staging", aws),
        ("github-token", "export GH_TOKEN=\(github)", github),
        ("github-pat", "token \(githubPAT) expires soon", githubPAT),
        ("anthropic-key", "ANTHROPIC=\(anthropic)", anthropic),
        ("openai-key", "use \(openAI) for the eval", openAI),
        ("slack-token", "bot: \(slack)", slack),
        ("slack-webhook", "post to \(slackWebhook) on deploy", slackWebhook),
        ("stripe-key", "stripe \(stripe)", stripe),
        ("google-api-key", "maps \(google)", google),
        ("jwt", "Authorization: Bearer \(jwt)", jwt),
        ("private-key", "here is the key:\n\(privateKey)\nkeep it safe", privateKey),
        ("generic-secret", "db password=\(password) for prod", password),
    ]

    static var allValues: [String] { cases.map(\.value) }

    /// One Claude Code transcript line (JSON) with `text` as the user's message.
    static func claudeLine(_ text: String, session: String = "eeeeeeee-5555-4555-8555-555555555555") -> String {
        let object: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
            "cwd": "/Users/dev/code/orbit-api",
            "sessionId": session,
            "timestamp": "2026-11-20T09:00:10.000Z",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
