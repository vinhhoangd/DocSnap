package com.vinhhoang.docsnap.ui.common

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BrokenImage
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Decoded page bitmaps, keyed by file + page version + size. Sized from the app's heap (see
 * [ImageSampling.cacheBytes]); full-screen pages too big for it are decoded but not kept.
 */
object PageImageCache {
    private val maxHeap = Runtime.getRuntime().maxMemory()
    private val maxBytes = ImageSampling.cacheBytes(maxHeap)
    private val cache = object : LruCache<String, Bitmap>((maxBytes / 1024).toInt()) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount / 1024
    }

    /** Longest side the full-screen viewer should ask for on this phone. */
    val viewerMaxSide: Int = ImageSampling.viewerMaxSide(maxHeap)

    fun get(key: String): Bitmap? = cache.get(key)

    /** Decodes `file` with its longest side at most `maxSide` px. Call off the main thread. */
    fun load(file: File, version: Int, maxSide: Int): Bitmap? {
        val key = ImageSampling.cacheKey(file.absolutePath, version, maxSide)
        cache.get(key)?.let { return it }
        if (!file.exists()) return null
        val bitmap = try {
            decode(file, maxSide)
        } catch (_: OutOfMemoryError) {
            // Free the thumbnails and try once more at half the size.
            cache.evictAll()
            runCatching { decode(file, maxSide / 2) }.getOrNull()
        } ?: return null
        if (ImageSampling.fitsCache(bitmap.allocationByteCount.toLong(), maxBytes)) cache.put(key, bitmap)
        return bitmap
    }

    private fun decode(file: File, maxSide: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // Decodes straight to the exact size (sampling internally), so a 4096 px page never
            // needs a full-size bitmap.
            return ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                val (w, h) = ImageSampling.targetSize(info.size.width, info.size.height, maxSide)
                decoder.setTargetSize(w, h)
                // Software bitmaps: drawable everywhere (also in screenshots and tests).
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        // Android 8: power-of-two sampling, never larger than maxSide (may be up to half of it).
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = ImageSampling.inSampleSize(bounds.outWidth, bounds.outHeight, maxSide)
        }
        return BitmapFactory.decodeFile(file.absolutePath, options)
    }
}

private sealed interface Loaded {
    data object Loading : Loaded
    data object Failed : Loaded
    data class Ready(val image: ImageBitmap) : Loaded
}

/**
 * A page image decoded off the main thread. While a new version decodes, the previous image stays
 * on screen (no flash); before the first decode a tinted placeholder shows.
 */
@Composable
fun PageImage(
    file: File,
    version: Int,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    maxSide: Int = 600,
    contentScale: ContentScale = ContentScale.Fit,
) {
    val cached = PageImageCache.get(ImageSampling.cacheKey(file.absolutePath, version, maxSide))
    val state by produceState<Loaded>(
        initialValue = cached?.let { Loaded.Ready(it.asImageBitmap()) } ?: Loaded.Loading,
        file, version, maxSide,
    ) {
        val bitmap = withContext(Dispatchers.IO) { runCatching { PageImageCache.load(file, version, maxSide) }.getOrNull() }
        value = if (bitmap != null) Loaded.Ready(bitmap.asImageBitmap()) else Loaded.Failed
    }
    when (val s = state) {
        is Loaded.Ready -> Image(
            bitmap = s.image,
            contentDescription = contentDescription,
            contentScale = contentScale,
            modifier = modifier,
        )
        Loaded.Loading -> Box(
            modifier
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .semantics { contentDescription?.let { this.contentDescription = it } },
        )
        Loaded.Failed -> Box(
            modifier
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .semantics { contentDescription?.let { this.contentDescription = it } },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Outlined.BrokenImage,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(32.dp),
            )
        }
    }
}
