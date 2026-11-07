package dev.phonedisplay.app

import java.net.InetSocketAddress
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

object PinnedTls {
    fun connect(host: String, port: Int, fingerprint: String, timeoutMs: Int = 5_000): SSLSocket {
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf(PinningTrustManager(fingerprint)), SecureRandom())
        val socket = context.socketFactory.createSocket() as SSLSocket
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress(host, port), timeoutMs)
        socket.soTimeout = timeoutMs
        val supported = socket.supportedProtocols
        val protocols = supported.filter { it == "TLSv1.2" || it == "TLSv1.3" }
        if (protocols.isNotEmpty()) {
            socket.enabledProtocols = protocols.toTypedArray()
        }
        socket.sslParameters = socket.sslParameters.apply {
            endpointIdentificationAlgorithm = null
        }
        socket.startHandshake()
        return socket
    }

    private class PinningTrustManager(private val expected: String) : X509TrustManager {
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
            throw CertificateException("client certificates are not accepted")
        }

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
            val certificate = chain.firstOrNull()
                ?: throw CertificateException("the Mac sent no certificate")
            val actual = sha256Hex(certificate.encoded)
            if (!MessageDigest.isEqual(
                    actual.toByteArray(Charsets.US_ASCII),
                    expected.lowercase().toByteArray(Charsets.US_ASCII),
                )
            ) {
                throw CertificateException("the Mac identity changed")
            }
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    private fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data)
            .joinToString("") { "%02x".format(it) }
}
