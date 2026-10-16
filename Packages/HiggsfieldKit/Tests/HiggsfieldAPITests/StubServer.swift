import HiggsfieldAPI
import HiggsfieldTestSupport

extension StubServer {
    func makeClient(keyID: String = "key-id", secret: String = "key-secret") -> HiggsfieldAPIClient {
        HiggsfieldAPIClient(keyID: keyID, secret: secret, baseURL: baseURL, session: StubServer.makeSession())
    }
}
