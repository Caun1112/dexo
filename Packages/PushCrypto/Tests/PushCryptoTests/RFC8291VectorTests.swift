import Foundation
import Testing
@testable import PushCrypto

@Test func decryptsRFC8291Section5Vector() throws {
    let body = try Base64URL.decode(
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" +
        "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" +
        "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
    )
    let material = try WebPushKeyMaterial(
        privateKey: Base64URL.decode("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"),
        publicKey: Base64URL.decode(
            "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyP" +
            "js7Vd8pZGH6SRpkNtoIAiw4"
        ),
        authenticationSecret: Base64URL.decode("BTBZMqHH6r4Tts7J_aSIgg")
    )

    let plaintext = try WebPushDecryptor.decrypt(body: body, keyMaterial: material)

    #expect(String(data: plaintext, encoding: .utf8) == "When I grow up, I want to be a watermelon")
}

@Test func generatedKeyMaterialHasWebPushShapes() throws {
    let material = try WebPushKeyMaterial.generate()

    #expect(material.privateKey.count == 32)
    #expect(material.publicKey.count == 65)
    #expect(material.publicKey.first == 0x04)
    #expect(material.authenticationSecret.count == 16)
    #expect(try Base64URL.decode(material.p256dh) == material.publicKey)
    #expect(try Base64URL.decode(material.auth) == material.authenticationSecret)
}
