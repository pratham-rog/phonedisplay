package dev.phonedisplay.app

import android.content.Context
import android.net.Uri

data class PairingInfo(
    val host: String,
    val port: Int,
    val fingerprint: String,
    val token: String,
    val hostID: String,
    val name: String,
)

data class SavedDevice(
    val host: String,
    val port: Int,
    val fingerprint: String,
    val hostID: String,
    val deviceID: String,
    val secret: String,
    val name: String,
)

object PairingParser {
    private val fingerprintPattern = Regex("^[0-9a-fA-F]{64}$")

    fun parse(raw: String): PairingInfo? {
        val uri = try {
            Uri.parse(raw)
        } catch (_: Exception) {
            return null
        }
        if (uri.scheme != "phonedisplay" || uri.host != "pair") return null
        if (uri.getQueryParameter("v") != "1") return null
        val host = uri.getQueryParameter("host")?.trim().orEmpty()
        val port = uri.getQueryParameter("port")?.toIntOrNull() ?: return null
        val fingerprint = uri.getQueryParameter("fp")?.trim().orEmpty()
        val token = uri.getQueryParameter("token")?.trim().orEmpty()
        val hostID = uri.getQueryParameter("id")?.trim().orEmpty()
        val name = uri.getQueryParameter("name")?.trim().orEmpty().ifEmpty { "Mac" }
        if (host.isEmpty() || port !in 1..65535) return null
        if (!fingerprintPattern.matches(fingerprint)) return null
        if (token.isEmpty() || hostID.isEmpty()) return null
        return PairingInfo(
            host = host,
            port = port,
            fingerprint = fingerprint.lowercase(),
            token = token,
            hostID = hostID,
            name = name,
        )
    }
}

class PairingStore(context: Context) {
    private val prefs = context.getSharedPreferences("pd", Context.MODE_PRIVATE)
    private val secrets = SecretStore(context)

    init {
        // The old plaintext build stored host:port#token here.
        if (prefs.contains("host")) {
            prefs.edit().remove("host").apply()
        }
    }

    fun load(): SavedDevice? {
        val host = prefs.getString("pd_host", null) ?: return null
        val port = prefs.getInt("pd_port", 0)
        val fingerprint = prefs.getString("pd_fp", null) ?: return null
        val hostID = prefs.getString("pd_host_id", null) ?: return null
        val deviceID = prefs.getString("pd_device_id", null) ?: return null
        val secret = secrets.load() ?: prefs.getString("pd_secret", null)?.also {
            // Migrate a secret written by the pre-Keystore build.
            secrets.save(it)
        } ?: return null
        val name = prefs.getString("pd_name", null) ?: "Mac"
        if (host.isEmpty() || port !in 1..65535) return null
        if (!Regex("^[0-9a-f]{64}$").matches(fingerprint)) return null
        if (hostID.isEmpty() || deviceID.isEmpty() || secret.isEmpty()) return null
        return SavedDevice(host, port, fingerprint, hostID, deviceID, secret, name)
    }

    fun save(device: SavedDevice) {
        secrets.save(device.secret)
        prefs.edit()
            .putString("pd_host", device.host)
            .putInt("pd_port", device.port)
            .putString("pd_fp", device.fingerprint)
            .putString("pd_host_id", device.hostID)
            .putString("pd_device_id", device.deviceID)
            .putString("pd_name", device.name)
            .apply()
    }

    fun clear() {
        secrets.clear()
        prefs.edit()
            .remove("pd_host")
            .remove("pd_port")
            .remove("pd_fp")
            .remove("pd_host_id")
            .remove("pd_device_id")
            .remove("pd_secret")
            .remove("pd_name")
            .remove("host")
            .apply()
    }
}
