// The EdDSA (Ed25519) key that signs betterlink's updates. Sparkle checks
// every downloaded update against the public half, SUPublicEDKey in
// Info.plist, before installing it.
//
//   swift scripts/update-key.swift keygen <private-key-file>
//       Makes a key pair. Writes the private key (base64 of the 32-byte seed)
//       to the file, readable only by you, and prints the public key.
//   swift scripts/update-key.swift sign <private-key-file> <file>
//       Prints the base64 signature of <file>.
//   swift scripts/update-key.swift verify <public-key> <signature> <file>
//       Exits 0 when the signature is good.
//   swift scripts/update-key.swift public <private-key-file>
//       Prints the public key that belongs to a private key.
//
// CryptoKit only, so no download is needed to make or use the key.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func privateKey(at path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("Can't read \(path).") }
    guard let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    else { fail("\(path) isn't an update key (base64 of 32 bytes).") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("keygen", 2):
    let path = args[1]
    if FileManager.default.fileExists(atPath: path) { fail("\(path) already exists; not overwriting a key.") }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600])
    else { fail("Can't write \(path).") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("public", 2):
    print(privateKey(at: args[1]).publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("Can't read \(args[2]).") }
    guard let sig = try? privateKey(at: args[1]).signature(for: data) else { fail("Signing failed.") }
    print(sig.base64EncodedString())
case ("verify", 4):
    guard let pub = Data(base64Encoded: args[1]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub)
    else { fail("Not a public key: \(args[1])") }
    guard let sig = Data(base64Encoded: args[2]) else { fail("Not a signature.") }
    guard let data = FileManager.default.contents(atPath: args[3]) else { fail("Can't read \(args[3]).") }
    if !key.isValidSignature(sig, for: data) { fail("The signature does not match \(args[3]) and this public key.") }
default:
    fail("Usage: update-key.swift keygen <file> | public <file> | sign <key-file> <file> | verify <public-key> <signature> <file>")
}
