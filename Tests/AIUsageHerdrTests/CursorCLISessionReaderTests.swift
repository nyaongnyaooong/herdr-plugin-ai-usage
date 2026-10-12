import Foundation
import Testing
import AIUsageCore

struct CursorCLISessionReaderTests {
    @Test func readsTokenFromAuthFile() throws {
        let directory = try makeDirectory()
        let auth = directory.appendingPathComponent("auth.json")
        try #"{"accessToken":"file-token","email":"a@b.c"}"#.write(to: auth, atomically: true, encoding: .utf8)
        let reader = CursorCLISessionReader(
            authFileURLs: [auth],
            cliConfigURL: nil,
            keychainPassword: { _, _ in "keychain-token" }
        )
        let session = reader.readSession()
        #expect(session?.accessToken == "file-token")
        #expect(session?.email == "a@b.c")
    }

    @Test func readsKeychainWhenAuthFileMissing() throws {
        let directory = try makeDirectory()
        let config = directory.appendingPathComponent("cli-config.json")
        try #"{"authInfo":{"email":"cli@b.c","displayName":"CLI User"}}"#.write(to: config, atomically: true, encoding: .utf8)
        let reader = CursorCLISessionReader(
            authFileURLs: [directory.appendingPathComponent("missing.json")],
            cliConfigURL: config,
            keychainPassword: { service, account in
                if service == CursorCLISessionReader.accessTokenService && account == CursorCLISessionReader.keychainAccount {
                    return "keychain-token"
                }
                return nil
            }
        )
        let session = reader.readSession()
        #expect(session?.accessToken == "keychain-token")
        #expect(session?.email == "cli@b.c")
        #expect(session?.displayName == "CLI User")
    }

    @Test func returnsNilWithoutFileOrKeychain() {
        let reader = CursorCLISessionReader(
            authFileURLs: [],
            cliConfigURL: nil,
            keychainPassword: { _, _ in "  " }
        )
        #expect(reader.readSession() == nil)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
