package app.androp.android.data.ble

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * A short rotating proof in the advertisement that this phone holds the pairing token.
 *
 * Android rotates its private Bluetooth address, which gives the phone a new identity
 * on the Mac every few minutes. The proof lets the Mac recognise its phone under any
 * address without sending the token to an unknown advertiser. The token itself never
 * leaves the phone. Must match BLEAdvertisementProof.swift.
 */
object BleAdvertisementProof {
    /** Bluetooth SIG "reserved for testing" company ID; the payload is app-defined. */
    const val MANUFACTURER_ID = 0xFFFF
    const val PROOF_BYTES = 5
    const val WINDOW_SECONDS = 600L

    fun window(epochSeconds: Long = System.currentTimeMillis() / 1000): Long = epochSeconds / WINDOW_SECONDS

    fun proof(authToken: String, window: Long): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(authToken.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        return mac.doFinal("androp-ble:$window".toByteArray(Charsets.UTF_8)).copyOf(PROOF_BYTES)
    }

    /** Milliseconds until the advertisement must carry the next window's proof. */
    fun millisUntilNextWindow(epochMillis: Long = System.currentTimeMillis()): Long =
        WINDOW_SECONDS * 1000 - epochMillis % (WINDOW_SECONDS * 1000)
}
