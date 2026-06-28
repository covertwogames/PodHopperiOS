import XCTest
@testable import PocketCastsServer

/// Verifies the Supabase client builds each request with exactly the headers the backend expects.
/// Getting these wrong is the most likely way to silently break interop with the Android app and the
/// car, so they are pinned here. No network is involved; only request construction is checked.
final class PodHopperSupabaseClientTests: XCTestCase {

    private let client = PodHopperSupabaseClient()
    private let anonKey = "sb_publishable_mkv0y6AoTSkPoY6MekLj2g_ZOqpdKVv"
    private let baseURL = "https://vamqoxkasykfhnlfeixz.supabase.co"

    func testAuthRequestSendsApiKeyOnlyNeverABearer() throws {
        let request = try client.makeAuthRequest(
            path: "/auth/v1/token?grant_type=password",
            body: ["email": "a@b.com", "password": "secret"]
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, baseURL + "/auth/v1/token?grant_type=password")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), anonKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) // auth calls must not send a bearer
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["email"] as? String, "a@b.com")
        XCTAssertEqual(json["password"] as? String, "secret")
    }

    func testPairingRequestSendsAnonKeyAsBearer() throws {
        let request = try client.makePairingRequest(body: ["action": "start", "device_name": "iPhone"])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, baseURL + "/functions/v1/pairing")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), anonKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + anonKey)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "start")
        XCTAssertEqual(json["device_name"] as? String, "iPhone")
    }

    func testRestRequestSendsUserAccessTokenAsBearer() {
        let url = baseURL + "/rest/v1/subscriptions?on_conflict=user_id,feed_url"
        let request = client.makeRestRequest(url: url, token: "USER_TOKEN")
        XCTAssertEqual(request.url?.absoluteString, url) // comma in on_conflict survives URL construction
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), anonKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer USER_TOKEN")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testNotSignedInSessionThrows() {
        // When there is no stored refresh token, building a session must fail with notSignedIn rather
        // than hitting the network. Guarded so a Keychain left signed in from another run does not
        // make this flap.
        if !client.isLoggedIn() {
            XCTAssertThrowsError(try client.ensureSession()) { error in
                guard case SupabaseError.notSignedIn = error else {
                    return XCTFail("expected notSignedIn, got \(error)")
                }
            }
        }
    }
}
