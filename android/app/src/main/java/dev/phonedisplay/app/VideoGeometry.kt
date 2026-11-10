package dev.phonedisplay.app

import kotlin.math.max

/** Shared center-crop math so the video and the pen use identical coordinates. */
object VideoGeometry {
    fun scale(videoW: Int, videoH: Int, viewW: Int, viewH: Int): Float =
        if (videoW > 0 && videoH > 0 && viewW > 0 && viewH > 0)
            max(viewW.toFloat() / videoW, viewH.toFloat() / videoH)
        else 1f

    fun offsetX(videoW: Int, viewW: Int, scale: Float): Float =
        if (videoW > 0) (viewW - videoW * scale) / 2f else 0f

    fun offsetY(videoH: Int, viewH: Int, scale: Float): Float =
        if (videoH > 0) (viewH - videoH * scale) / 2f else 0f

    fun toStreamX(rawX: Float, videoW: Int, viewW: Int, scale: Float): Float =
        if (videoW > 0 && scale > 0f)
            (rawX - offsetX(videoW, viewW, scale)) / scale
        else 0f

    fun toStreamY(rawY: Float, videoH: Int, viewH: Int, scale: Float): Float =
        if (videoH > 0 && scale > 0f)
            (rawY - offsetY(videoH, viewH, scale)) / scale
        else 0f
}
