import Foundation
import Testing
@testable import PushCrypto

private func vectorMaterial() throws -> WebPushKeyMaterial {
    try WebPushKeyMaterial(
        privateKey: Base64URL.decode("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"),
        publicKey: Base64URL.decode(
            "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyP" +
            "js7Vd8pZGH6SRpkNtoIAiw4"
        ),
        authenticationSecret: Base64URL.decode("BTBZMqHH6r4Tts7J_aSIgg")
    )
}

private func vectorBody() throws -> Data {
    try Base64URL.decode(
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" +
        "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" +
        "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
    )
}

@Test func rejectsTamperedCiphertext() throws {
    var body = try vectorBody()
    body[body.index(before: body.endIndex)] ^= 1

    #expect(throws: PushCryptoError.authenticationFailed) {
        try WebPushDecryptor.decrypt(body: body, keyMaterial: vectorMaterial())
    }
}

@Test func rejectsOversizedBodyBeforeParsing() throws {
    #expect(throws: PushCryptoError.payloadTooLarge) {
        try WebPushDecryptor.decrypt(
            body: Data(repeating: 0, count: 100),
            keyMaterial: vectorMaterial(),
            maximumBodySize: 99
        )
    }
}

@Test func rejectsWrongAuthenticationSecret() throws {
    let original = try vectorMaterial()
    let wrong = try WebPushKeyMaterial(
        privateKey: original.privateKey,
        publicKey: original.publicKey,
        authenticationSecret: Data(repeating: 7, count: 16)
    )

    #expect(throws: PushCryptoError.authenticationFailed) {
        try WebPushDecryptor.decrypt(body: vectorBody(), keyMaterial: wrong)
    }
}
