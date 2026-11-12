package com.vinhhoang.docsnap.ui.common

import android.graphics.Bitmap
import android.graphics.BitmapFactory
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

/** Decoded page bitmaps, keyed by file + page version + size, sized to an eighth of the app's heap. */
object PageImageCache {
    private val maxKb = (Runtime.getRuntime().maxMemory() / 1024 / 8).toInt()
    private val cache = object : LruCache<String, Bitmap>(maxKb) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount / 1024
    }

    fun get(key: String): Bitmap? = cache.get(key)

    /** Decodes `file` with its longest side at most about `maxSide` px. Call off the main thread. */
    fun load(file: File, version: Int, maxSide: Int): Bitmap? {
        val key = ImageSampling.cacheKey(file.absolutePath, version, maxSide)
        cache.get(key)?.let { return it }
        if (!file.exists()) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = ImageSampling.inSampleSize(bounds.outWidth, bounds.outHeight, maxSide)
        }
        val bitmap = try {
            BitmapFactory.decodeFile(file.absolutePath, options)
        } catch (_: OutOfMemoryError) {
            cache.evictAll()
            null
        } ?: return null
        cache.put(key, bitmap)
        return bitmap
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
