package app.androp.android.utils

/** Choose only directly attached routes. A VPN always retains control of routing. */
internal object LocalSocketRouting {
    data class Candidate(val index: Int, val prefixLength: Int, val address: ByteArray)

    fun select(target: ByteArray, candidates: List<Candidate>, vpnPresent: Boolean): Int? {
        if (vpnPresent || target.size !in setOf(4, 16)) return null
        return candidates.filter { candidate ->
            val prefix = candidate.prefixLength
            if (candidate.address.size != target.size || prefix !in 1..target.size * 8) false
            else {
                val whole = prefix / 8
                val remainder = prefix % 8
                (0 until whole).all { target[it] == candidate.address[it] } &&
                    (remainder == 0 || ((target[whole].toInt() xor candidate.address[whole].toInt()) and
                        (0xff shl (8 - remainder))) == 0)
            }
        }.maxByOrNull { it.prefixLength }?.index
    }
}
