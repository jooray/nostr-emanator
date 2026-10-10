package today.cypherpunk.nostrsignin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class Nip55ParseTest {
    private val pubkey = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
    private val event = UnsignedEvent.loginProof(pubkey, "abc123", "https://example.com/api/v1/auth/token", 1700000000)
    private val sig = "803cd1b8c524ed92331547e8c6ff037fdd0934068f4401b6f144a910fd2bf8b5379acfba962a7a382be6071800c1d0001566ddf58966b3364d7f79dbe1e30a70"
    private val signedByNak = """{"kind":27235,"id":"${event.id}","pubkey":"$pubkey","created_at":1700000000,"tags":[["u","https://example.com/api/v1/auth/token"],["method","POST"],["challenge","abc123"]],"content":"","sig":"$sig"}"""

    private fun extras(vararg pairs: Pair<String, String>): (String) -> String? = mapOf(*pairs)::get

    @Test fun publicKeyAsNpubOrHex() {
        val npub = Bech32.npub(pubkey)
        assertEquals(Nip55.Reply.PublicKey(pubkey, "com.signer"), Nip55.parsePublicKey(extras("result" to npub, "package" to "com.signer")))
        assertEquals(Nip55.Reply.PublicKey(pubkey, null), Nip55.parsePublicKey(extras("result" to pubkey)))
        assertEquals(Nip55.Reply.Empty, Nip55.parsePublicKey(extras("result" to "nonsense")))
    }

    @Test fun wholeEvent() {
        val reply = Nip55.parseSigned(event, extras("event" to signedByNak, "result" to sig))
        assertEquals(Nip55.Reply.Signed(event.signedJson(sig)), reply)
    }

    @Test fun signatureOnly() {
        assertEquals(Nip55.Reply.Signed(event.signedJson(sig)), Nip55.parseSigned(event, extras("result" to sig)))
        assertEquals(Nip55.Reply.Signed(event.signedJson(sig)), Nip55.parseSigned(event, extras("signature" to sig.uppercase())))
    }

    @Test fun batchedResults() {
        val results = """[{"package":"com.signer","result":"$sig","id":"${event.id}"}]"""
        assertEquals(Nip55.Reply.Signed(event.signedJson(sig)), Nip55.parseSigned(event, extras("results" to results)))
    }

    @Test fun refusesSomeoneElsesEvent() {
        val other = signedByNak.replace("1700000000", "1700000005")
        assertEquals(Nip55.Reply.Empty, Nip55.parseSigned(event, extras("event" to other)))
        assertEquals(Nip55.Reply.Empty, Nip55.parseSigned(event, extras("result" to "not-a-signature")))
    }

    @Test fun signedJsonIsCanonical() {
        val json = event.signedJson(sig)
        assertTrue(json.startsWith("{\"id\":\"${event.id}\",\"pubkey\":\"$pubkey\""))
        assertTrue(json.endsWith("\"sig\":\"$sig\"}"))
    }
}
