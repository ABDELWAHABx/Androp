package app.androp.android.utils

import android.graphics.Bitmap
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.lang.ref.WeakReference
import kotlin.math.roundToInt

/** Encodes unchanged artwork once, with bounded image and cache sizes. */
object MediaArtworkCache {
    private data class Entry(val bitmap: WeakReference<Bitmap>, val generation: Int,
                             val artwork: Pair<String?, String?>)
    private val entries = ArrayDeque<Entry>()

    @Synchronized fun encode(bitmap: Bitmap?): Pair<String?, String?> {
        if (bitmap == null || bitmap.isRecycled) return null to null
        entries.firstOrNull { it.bitmap.get() === bitmap && it.generation == bitmap.generationId }
            ?.let { return it.artwork }
        val generation = bitmap.generationId
        val encoded = jpeg(bitmap, 256, 50) to jpeg(bitmap, 80, 30)
        // Do not cache old pixels under a newer generation when mutable artwork changes mid-encode.
        if (!bitmap.isRecycled && bitmap.generationId == generation) {
            entries.addLast(Entry(WeakReference(bitmap), generation, encoded))
        }
        while (entries.size > 4) entries.removeFirst()
        return encoded
    }

    @Synchronized fun clear() { entries.clear() }

    private fun jpeg(bitmap: Bitmap, maximumDimension: Int, quality: Int): String? {
        val ratio = minOf(1.0, maximumDimension.toDouble() / maxOf(bitmap.width, bitmap.height))
        val scaled = if (ratio < 1.0) Bitmap.createScaledBitmap(bitmap,
            (bitmap.width * ratio).roundToInt().coerceAtLeast(1),
            (bitmap.height * ratio).roundToInt().coerceAtLeast(1), true) else bitmap
        return try {
            ByteArrayOutputStream().use { output ->
                if (!scaled.compress(Bitmap.CompressFormat.JPEG, quality, output)) null
                else Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
            }
        } finally {
            if (scaled !== bitmap) scaled.recycle()
        }
    }
}
