package com.kkremote.android.crypto

import com.kkremote.android.protocol.TrustedHostProfile
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

@Serializable
private data class StoredClientIdentity(
    val version: Int = 1,
    val signPrivPkcs8B64: String,
    val signPubSpkiB64: String,
    val kexPrivPkcs8B64: String,
    val kexPubSpkiB64: String,
)

data class SealedEnvelope(
    val nonceB64: String,
    val ciphertextB64: String,
    val payloadSigB64: String,
)

/**
 * Cross-platform P-256 (ECDSA + ECDH + HKDF-SHA256 + AES-256-GCM) device identity.
 * Wire-compatible byte-for-byte with macOS/iOS DeviceIdentity.swift and Server/Coord/main.go.
 */
class DeviceIdentity private constructor(
    private val signPrivateKey: PrivateKey,
    val signPublicKey: PublicKey,
    private val kexPrivateKey: PrivateKey,
    val kexPublicKey: PublicKey,
) {
    val signPubB64: String = Base64.getEncoder().encodeToString(signPublicKey.encoded)
    val kexPubB64: String = Base64.getEncoder().encodeToString(kexPublicKey.encoded)
    val deviceId: String = sha256(signPublicKey.encoded).copyOfRange(0, 16).toHexLower()

    fun signP1363(message: String): String {
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(signPrivateKey, secureRandom)
        signer.update(message.toByteArray(StandardCharsets.UTF_8))
        val der = signer.sign()
        return Base64.getEncoder().encodeToString(derToP1363(der))
    }

    fun deriveSessionKey(peerKexSpkiB64: String, sessionId: String): SecretKeySpec {
        val peerKexPub = decodeEcPublicKey(peerKexSpkiB64)
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(kexPrivateKey)
        agreement.doPhase(peerKexPub, true)
        val rawSecret = agreement.generateSecret()
        val sharedSecret = when {
            rawSecret.size == 32 -> rawSecret
            rawSecret.size < 32 -> ByteArray(32 - rawSecret.size) + rawSecret
            else -> rawSecret.copyOfRange(rawSecret.size - 32, rawSecret.size)
        }
        val okm = hkdfSha256(
            ikm = sharedSecret,
            salt = sessionId.toByteArray(StandardCharsets.UTF_8),
            info = "kkremote-coord-e2ee-v1".toByteArray(StandardCharsets.UTF_8),
            outputBytes = 32,
        )
        return SecretKeySpec(okm, "AES")
    }

    fun sealUtf8(
        plaintextJson: String,
        sessionId: String,
        toPeerId: String,
        kind: String,
        key: SecretKeySpec,
    ): SealedEnvelope {
        val iv = ByteArray(12).also { secureRandom.nextBytes(it) }
        val nonceB64 = Base64.getEncoder().encodeToString(iv)
        val aad = "kkremote-e2ee-v1|$sessionId|$deviceId|$toPeerId|$kind".toByteArray(StandardCharsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        val ctAndTag = cipher.doFinal(plaintextJson.toByteArray(StandardCharsets.UTF_8))
        val ciphertextB64 = Base64.getEncoder().encodeToString(ctAndTag)
        val sigInput = "kkremote-e2ee-sig-v1|$sessionId|$deviceId|$toPeerId|$kind|$nonceB64|$ciphertextB64"
        val payloadSigB64 = signP1363(sigInput)
        return SealedEnvelope(nonceB64 = nonceB64, ciphertextB64 = ciphertextB64, payloadSigB64 = payloadSigB64)
    }

    fun openUtf8(
        sessionId: String,
        fromPeerId: String,
        peerSignSpkiB64: String,
        kind: String,
        nonceB64: String,
        ciphertextB64: String,
        sigB64: String,
        key: SecretKeySpec,
    ): String {
        val sigInput = "kkremote-e2ee-sig-v1|$sessionId|$fromPeerId|$deviceId|$kind|$nonceB64|$ciphertextB64"
        if (!verifyP1363(peerSignSpkiB64, sigInput, sigB64)) {
            throw SecurityException("远端 E2EE 载荷签名校验失败")
        }
        val iv = decodeFlexibleBase64(nonceB64)
        require(iv.size == 12) { "E2EE Nonce 长度非法" }
        val aad = "kkremote-e2ee-v1|$sessionId|$fromPeerId|$deviceId|$kind".toByteArray(StandardCharsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        val pt = cipher.doFinal(decodeFlexibleBase64(ciphertextB64))
        return String(pt, StandardCharsets.UTF_8)
    }

    companion object {
        private val secureRandom = SecureRandom()
        private val storageJson = Json { ignoreUnknownKeys = true }

        fun generate(): DeviceIdentity {
            val kpg = KeyPairGenerator.getInstance("EC")
            kpg.initialize(ECGenParameterSpec("secp256r1"), secureRandom)
            val signKp = kpg.generateKeyPair()
            val kexKp = kpg.generateKeyPair()
            return DeviceIdentity(signKp.private, signKp.public, kexKp.private, kexKp.public)
        }

        fun loadOrCreate(file: File): DeviceIdentity {
            if (file.exists()) {
                runCatching {
                    val parsed = storageJson.decodeFromString<StoredClientIdentity>(file.readText(StandardCharsets.UTF_8))
                    val kf = KeyFactory.getInstance("EC")
                    val signPriv = kf.generatePrivate(PKCS8EncodedKeySpec(decodeFlexibleBase64(parsed.signPrivPkcs8B64)))
                    val signPub = kf.generatePublic(X509EncodedKeySpec(decodeFlexibleBase64(parsed.signPubSpkiB64)))
                    val kexPriv = kf.generatePrivate(PKCS8EncodedKeySpec(decodeFlexibleBase64(parsed.kexPrivPkcs8B64)))
                    val kexPub = kf.generatePublic(X509EncodedKeySpec(decodeFlexibleBase64(parsed.kexPubSpkiB64)))
                    return DeviceIdentity(signPriv, signPub, kexPriv, kexPub)
                }
            }
            val fresh = generate()
            file.parentFile?.mkdirs()
            val stored = StoredClientIdentity(
                signPrivPkcs8B64 = Base64.getEncoder().encodeToString(fresh.signPrivateKey.encoded),
                signPubSpkiB64 = fresh.signPubB64,
                kexPrivPkcs8B64 = Base64.getEncoder().encodeToString(fresh.kexPrivateKey.encoded),
                kexPubSpkiB64 = fresh.kexPubB64,
            )
            file.writeText(storageJson.encodeToString(stored), StandardCharsets.UTF_8)
            file.setReadable(false, false)
            file.setReadable(true, true)
            file.setWritable(false, false)
            file.setWritable(true, true)
            return fresh
        }

        fun randomHex(byteCount: Int = 12): String {
            val b = ByteArray(byteCount)
            secureRandom.nextBytes(b)
            return b.toHexLower()
        }

        fun decodeFlexibleBase64(input: String): ByteArray {
            val cleaned = input.trim().replace('-', '+').replace('_', '/')
            val pad = (4 - cleaned.length % 4) % 4
            return Base64.getDecoder().decode(cleaned + "=".repeat(pad))
        }

        fun decodeEcPublicKey(spkiB64: String): PublicKey {
            val spki = decodeFlexibleBase64(spkiB64)
            return KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(spki))
        }

        fun verifyP1363(peerSignSpkiB64: String, message: String, sigP1363B64: String): Boolean {
            return runCatching {
                val pub = decodeEcPublicKey(peerSignSpkiB64)
                val raw = decodeFlexibleBase64(sigP1363B64)
                if (raw.size != 64) return false
                val der = p1363ToDer(raw)
                val verifier = Signature.getInstance("SHA256withECDSA")
                verifier.initVerify(pub)
                verifier.update(message.toByteArray(StandardCharsets.UTF_8))
                verifier.verify(der)
            }.getOrDefault(false)
        }

        fun extractDtlsFingerprints(sdp: String): Set<String> =
            sdp.lineSequence()
                .map { it.trim() }
                .filter { it.startsWith("a=fingerprint:", ignoreCase = true) }
                .map { it.substringAfter(':').trim().uppercase() }
                .filter { it.isNotEmpty() }
                .toSet()

        /** Converts ASN.1 DER ECDSA signature to 64-byte IEEE P1363 (r || s). */
        internal fun derToP1363(der: ByteArray): ByteArray {
            require(der.size >= 8 && der[0] == 0x30.toByte()) { "Invalid ECDSA DER sequence" }
            var idx = 2
            if ((der[1].toInt() and 0x80) != 0) {
                val lenBytes = der[1].toInt() and 0x7f
                idx = 2 + lenBytes
            }
            require(der[idx] == 0x02.toByte()) { "Expected INTEGER r" }
            val rLen = der[idx + 1].toInt() and 0xff
            val rBytes = der.copyOfRange(idx + 2, idx + 2 + rLen)
            idx += 2 + rLen
            require(der[idx] == 0x02.toByte()) { "Expected INTEGER s" }
            val sLen = der[idx + 1].toInt() and 0xff
            val sBytes = der.copyOfRange(idx + 2, idx + 2 + sLen)

            val out = ByteArray(64)
            copyBigInt32(rBytes, out, 0)
            copyBigInt32(sBytes, out, 32)
            return out
        }

        /** Converts 64-byte IEEE P1363 (r || s) to canonical ASN.1 DER ECDSA signature. */
        internal fun p1363ToDer(raw64: ByteArray): ByteArray {
            require(raw64.size == 64) { "Expected 64-byte P1363 signature" }
            val rDer = encodeDerInt(raw64.copyOfRange(0, 32))
            val sDer = encodeDerInt(raw64.copyOfRange(32, 64))
            val bodyLen = rDer.size + sDer.size
            val out = ByteArrayOutputStream(2 + bodyLen)
            out.write(0x30)
            out.write(bodyLen)
            out.write(rDer)
            out.write(sDer)
            return out.toByteArray()
        }

        private fun copyBigInt32(src: ByteArray, dst: ByteArray, dstOffset: Int) {
            var start = 0
            while (start < src.size - 1 && src[start] == 0.toByte()) start++
            val significant = src.size - start
            require(significant <= 32) { "ECDSA component exceeds 32 bytes" }
            System.arraycopy(src, start, dst, dstOffset + (32 - significant), significant)
        }

        private fun encodeDerInt(raw32: ByteArray): ByteArray {
            var start = 0
            while (start < raw32.size - 1 && raw32[start] == 0.toByte()) start++
            val needsZeroPad = (raw32[start].toInt() and 0x80) != 0
            val len = (raw32.size - start) + if (needsZeroPad) 1 else 0
            val out = ByteArray(2 + len)
            out[0] = 0x02
            out[1] = len.toByte()
            var dstIdx = 2
            if (needsZeroPad) {
                out[dstIdx++] = 0x00
            }
            System.arraycopy(raw32, start, out, dstIdx, raw32.size - start)
            return out
        }

        /** RFC 5869 HKDF-SHA256. */
        internal fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, outputBytes: Int): ByteArray {
            val actualSalt = if (salt.isEmpty()) ByteArray(32) else salt
            val macExtract = Mac.getInstance("HmacSHA256")
            macExtract.init(SecretKeySpec(actualSalt, "HmacSHA256"))
            val prk = macExtract.doFinal(ikm)

            val macExpand = Mac.getInstance("HmacSHA256")
            macExpand.init(SecretKeySpec(prk, "HmacSHA256"))
            val result = ByteArray(outputBytes)
            var t = ByteArray(0)
            var offset = 0
            var counter = 1
            while (offset < outputBytes) {
                macExpand.reset()
                macExpand.update(t)
                macExpand.update(info)
                macExpand.update(counter.toByte())
                t = macExpand.doFinal()
                val toCopy = minOf(t.size, outputBytes - offset)
                System.arraycopy(t, 0, result, offset, toCopy)
                offset += toCopy
                counter++
            }
            return result
        }

        private fun sha256(bytes: ByteArray): ByteArray =
            MessageDigest.getInstance("SHA-256").digest(bytes)

        private fun ByteArray.toHexLower(): String = buildString(size * 2) {
            for (b in this@toHexLower) {
                val v = b.toInt() and 0xff
                append("0123456789abcdef"[v ushr 4])
                append("0123456789abcdef"[v and 0x0f])
            }
        }
    }
}

object PairingLinkParser {
    private val hex32 = Regex("^[0-9a-f]{32}$")

    /**
     * Parses either:
     * 1. https://coord.example.com/#host=<32hex>&pub=<spki>&kex=<spki>&pair=<tok>&name=<label>
     * 2. kkremote://pair?coord=https://coord.example.com#host=<32hex>&pub=...
     * 3. Raw #host=... fragment combined with an explicit fallbackCoordUrl
     */
    fun parse(rawInput: String, fallbackCoordUrl: String = ""): TrustedHostProfile? {
        val trimmed = rawInput.trim()
        if (trimmed.isEmpty()) return null

        val hashIdx = trimmed.indexOf('#')
        val beforeHash = if (hashIdx >= 0) trimmed.substring(0, hashIdx) else trimmed
        val fragment = when {
            hashIdx >= 0 -> trimmed.substring(hashIdx + 1)
            trimmed.contains("host=") && trimmed.contains("pub=") -> trimmed.trimStart('?', '#')
            else -> return null
        }

        val fragParams = parseQuery(fragment)
        val hostId = fragParams["host"]?.trim()?.lowercase() ?: return null
        if (!hex32.matches(hostId)) return null
        val pubRaw = fragParams["pub"]?.trim().orEmpty()
        val kexRaw = fragParams["kex"]?.trim().orEmpty()
        if (pubRaw.isEmpty() || kexRaw.isEmpty()) return null

        val normalizedSignPub = runCatching {
            val bytes = DeviceIdentity.decodeFlexibleBase64(pubRaw)
            DeviceIdentity.decodeEcPublicKey(Base64.getEncoder().encodeToString(bytes))
            Base64.getEncoder().encodeToString(bytes)
        }.getOrNull() ?: return null

        val normalizedKexPub = runCatching {
            val bytes = DeviceIdentity.decodeFlexibleBase64(kexRaw)
            DeviceIdentity.decodeEcPublicKey(Base64.getEncoder().encodeToString(bytes))
            Base64.getEncoder().encodeToString(bytes)
        }.getOrNull() ?: return null

        val coordUrl = resolveCoordBaseUrl(beforeHash, fragParams["coord"], fallbackCoordUrl) ?: return null
        val name = fragParams["name"]?.takeIf { it.isNotBlank() } ?: "Mac (${hostId.take(6)})"
        val pair = fragParams["pair"]?.takeIf { it.isNotBlank() }
        val autoselect = fragParams["autoselect"]?.takeIf { it.isNotBlank() }

        return TrustedHostProfile(
            coordUrl = coordUrl,
            hostId = hostId,
            name = name,
            signPub = normalizedSignPub,
            kexPub = normalizedKexPub,
            pendingPairToken = pair,
            autoSelectApp = autoselect,
        )
    }

    private fun resolveCoordBaseUrl(prefix: String, fragCoord: String?, fallback: String): String? {
        val candidates = buildList {
            if (!fragCoord.isNullOrBlank()) add(fragCoord)
            if (prefix.startsWith("https://", true) || prefix.startsWith("http://", true)) add(prefix)
            if (prefix.startsWith("kkremote://", true)) {
                runCatching {
                    val uri = URI(prefix)
                    val q = parseQuery(uri.rawQuery.orEmpty())
                    q["coord"]?.let { add(it) }
                }
            }
            if (fallback.isNotBlank()) add(fallback)
        }
        for (c in candidates) {
            val clean = c.trim().trimEnd('/')
            if (clean.startsWith("https://", true) || clean.startsWith("http://", true)) {
                return runCatching {
                    val u = URI(clean)
                    val portPart = if (u.port > 0) ":${u.port}" else ""
                    "${u.scheme.lowercase()}://${u.host}$portPart"
                }.getOrNull()
            }
        }
        return null
    }

    private fun parseQuery(raw: String): Map<String, String> {
        if (raw.isBlank()) return emptyMap()
        val out = LinkedHashMap<String, String>()
        for (pair in raw.split('&')) {
            if (pair.isBlank()) continue
            val eq = pair.indexOf('=')
            val k = if (eq >= 0) pair.substring(0, eq) else pair
            val v = if (eq >= 0) pair.substring(eq + 1) else ""
            val key = URLDecoder.decode(k, StandardCharsets.UTF_8.name())
            val value = URLDecoder.decode(v, StandardCharsets.UTF_8.name())
            out[key] = value
        }
        return out
    }
}
