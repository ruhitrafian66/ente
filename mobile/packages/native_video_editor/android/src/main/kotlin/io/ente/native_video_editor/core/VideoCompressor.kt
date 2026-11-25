package io.ente.native_video_editor.core

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.container.Mp4LocationData
import androidx.media3.container.Mp4TimestampData
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.InAppMp4Muxer
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File

// Offline fork: whole-file re-encode to HEVC for the "Compress videos" tool.
// Kept apart from VideoExportEngine so that the editor code stays as upstream.

/** What the container says about a video file. Nothing is decoded. */
data class VideoProbe(
    val videoMimeType: String?,
    val width: Int,
    val height: Int,
    val rotationDegrees: Int,
    val durationMs: Long,
    val frameRate: Float?,
    val frameCount: Int?,
    val videoBitrate: Int?,
    val audioBitrate: Int?,
    val videoTrackCount: Int,
    val audioTrackCount: Int,
    val otherTrackCount: Int,
    val isHdr: Boolean
)

data class VideoCompressRequest(
    val inputPath: String,
    val outputPath: String,
    val videoBitrate: Int,
    val iFrameIntervalSeconds: Float,
    val creationTimeMs: Long?
) {
    init {
        require(inputPath.isNotBlank() && outputPath.isNotBlank()) { "Missing video path" }
        require(videoBitrate > 0) { "Invalid video bitrate" }
        require(iFrameIntervalSeconds.isFinite() && iFrameIntervalSeconds > 0f) {
            "Invalid key frame interval"
        }
    }
}

data class VideoCompressResult(
    val outputPath: String,
    val fileSizeBytes: Long,
    val videoMimeType: String?,
    val videoEncoderName: String?,
    val averageVideoBitrate: Int,
    val videoFrameCount: Int,
    val width: Int,
    val height: Int,
    val isVideoReEncoded: Boolean,
    val isAudioReEncoded: Boolean
)

class VideoProbeReader {
    fun read(videoPath: String): VideoProbe {
        var videoFormat: MediaFormat? = null
        var audioFormat: MediaFormat? = null
        var videoTracks = 0
        var audioTracks = 0
        var otherTracks = 0

        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(videoPath)
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mimeType = format.getString(MediaFormat.KEY_MIME) ?: ""
                when {
                    mimeType.startsWith("video/") -> {
                        videoTracks++
                        if (videoFormat == null) videoFormat = format
                    }

                    mimeType.startsWith("audio/") -> {
                        audioTracks++
                        if (audioFormat == null) audioFormat = format
                    }

                    else -> otherTracks++
                }
            }
        } finally {
            extractor.release()
        }

        val video = requireNotNull(videoFormat) { "Input has no video track" }
        val width = video.intOrNull(MediaFormat.KEY_WIDTH) ?: 0
        val height = video.intOrNull(MediaFormat.KEY_HEIGHT) ?: 0
        require(width > 0 && height > 0) { "Video dimensions are unavailable" }
        val durationMs = (video.longOrNull(MediaFormat.KEY_DURATION) ?: 0L) / 1_000L
        val transfer = video.intOrNull(MediaFormat.KEY_COLOR_TRANSFER)
        val mimeType = video.getString(MediaFormat.KEY_MIME)

        var frameCount: Int? = null
        var rotation = video.intOrNull(MediaFormat.KEY_ROTATION)
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(videoPath)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                frameCount = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT
                )?.toIntOrNull()?.takeIf { it > 0 }
            }
            if (rotation == null) {
                rotation = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION
                )?.toIntOrNull()
            }
        } catch (_: Exception) {
            // The extractor values are enough.
        } finally {
            retriever.release()
        }

        var frameRate = video.floatOrNull(MediaFormat.KEY_FRAME_RATE)?.takeIf { it > 0f }
        if (frameRate == null && frameCount != null && durationMs > 0) {
            frameRate = frameCount * 1000f / durationMs
        }

        return VideoProbe(
            videoMimeType = mimeType,
            width = width,
            height = height,
            rotationDegrees = (((rotation ?: 0) % 360) + 360) % 360,
            durationMs = durationMs,
            frameRate = frameRate,
            frameCount = frameCount,
            videoBitrate = video.intOrNull(MediaFormat.KEY_BIT_RATE)?.takeIf { it > 0 },
            audioBitrate = audioFormat?.intOrNull(MediaFormat.KEY_BIT_RATE)?.takeIf { it > 0 },
            videoTrackCount = videoTracks,
            audioTrackCount = audioTracks,
            otherTrackCount = otherTracks,
            isHdr = transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
                transfer == MediaFormat.COLOR_TRANSFER_HLG ||
                mimeType == "video/dolby-vision"
        )
    }

    // A MediaFormat value can be stored as an int, a long or a float.
    private fun MediaFormat.numberOrNull(key: String): Number? {
        if (!containsKey(key)) return null
        return try {
            getInteger(key)
        } catch (_: Exception) {
            try {
                getLong(key)
            } catch (_: Exception) {
                try {
                    getFloat(key)
                } catch (_: Exception) {
                    null
                }
            }
        }
    }

    private fun MediaFormat.intOrNull(key: String): Int? = numberOrNull(key)?.toInt()

    private fun MediaFormat.longOrNull(key: String): Long? = numberOrNull(key)?.toLong()

    private fun MediaFormat.floatOrNull(key: String): Float? = numberOrNull(key)?.toFloat()
}

@UnstableApi
class VideoCompressor(private val context: Context) {
    suspend fun compress(
        request: VideoCompressRequest,
        onProgress: ((Float) -> Unit)? = null
    ): VideoCompressResult = withContext(Dispatchers.IO) {
        val inputFile = File(request.inputPath).canonicalFile
        val outputFile = File(request.outputPath).canonicalFile
        require(inputFile.isFile && inputFile != outputFile) {
            "Input must be a video file and output must be a different path"
        }

        try {
            val location = readLocation(inputFile.path)
            val item = EditedMediaItem.Builder(
                MediaItem.fromUri(Uri.fromFile(inputFile))
            ).build()
            val exportResult = withContext(Dispatchers.Main) {
                export(item, outputFile.path, request, location, onProgress)
            }
            require(outputFile.isFile && outputFile.length() > 0) {
                "Output file was not created"
            }
            VideoCompressResult(
                outputPath = request.outputPath,
                fileSizeBytes = outputFile.length(),
                videoMimeType = exportResult.videoMimeType,
                videoEncoderName = exportResult.videoEncoderName,
                averageVideoBitrate = exportResult.averageVideoBitrate,
                videoFrameCount = exportResult.videoFrameCount,
                width = exportResult.width,
                height = exportResult.height,
                isVideoReEncoded = exportResult.videoConversionProcess.isReEncode(),
                isAudioReEncoded = exportResult.audioConversionProcess.isReEncode()
            )
        } catch (error: CancellationException) {
            outputFile.delete()
            throw error
        } catch (error: Exception) {
            outputFile.delete()
            throw VideoProcessingException("Video compression failed: ${error.message}", error)
        }
    }

    private fun Int.isReEncode(): Boolean =
        this == ExportResult.CONVERSION_PROCESS_TRANSCODED ||
            this == ExportResult.CONVERSION_PROCESS_TRANSMUXED_AND_TRANSCODED

    private suspend fun export(
        item: EditedMediaItem,
        outputPath: String,
        request: VideoCompressRequest,
        location: Mp4LocationData?,
        onProgress: ((Float) -> Unit)?
    ): ExportResult = coroutineScope {
        var progressJob: Job? = null
        try {
            suspendCancellableCoroutine { continuation ->
                // A requested bitrate makes the encoder factory report that the
                // video needs an encode, so an HEVC input is not copied as is.
                val encoderFactory = DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder()
                            .setBitrate(request.videoBitrate)
                            .setiFrameIntervalSeconds(request.iFrameIntervalSeconds)
                            .build()
                    )
                    .build()
                val muxerFactory = InAppMp4Muxer.Factory(
                    InAppMp4Muxer.MetadataProvider { entries ->
                        request.creationTimeMs?.let { timeMs ->
                            val seconds = Mp4TimestampData.unixTimeToMp4TimeSeconds(timeMs)
                            entries.removeAll { it is Mp4TimestampData }
                            entries.add(Mp4TimestampData(seconds, seconds))
                        }
                        location?.let {
                            entries.removeAll { entry -> entry is Mp4LocationData }
                            entries.add(it)
                        }
                    }
                )
                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H265)
                    .setEncoderFactory(encoderFactory)
                    .setMuxerFactory(muxerFactory)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(
                            composition: Composition,
                            exportResult: ExportResult
                        ) {
                            if (continuation.isActive) {
                                onProgress?.invoke(1f)
                                continuation.resumeWith(Result.success(exportResult))
                            }
                        }

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException
                        ) {
                            if (continuation.isActive) {
                                continuation.resumeWith(Result.failure(exportException))
                            }
                        }
                    })
                    .build()

                continuation.invokeOnCancellation {
                    Handler(Looper.getMainLooper()).post(transformer::cancel)
                }
                transformer.start(item, outputPath)
                progressJob = launch {
                    val holder = ProgressHolder()
                    while (isActive && continuation.isActive) {
                        if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                            onProgress?.invoke(holder.progress / 100f)
                        }
                        delay(250)
                    }
                }
            }
        } finally {
            progressJob?.cancel()
        }
    }

    /** The ISO 6709 location of the input ("+37.4220-122.0840/"), if it has one. */
    private fun readLocation(videoPath: String): Mp4LocationData? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(videoPath)
            parseIso6709Location(
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
            )?.let { Mp4LocationData(it.first, it.second) }
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        }
    }
}

private val iso6709Pattern = Regex("""^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)""")

internal fun parseIso6709Location(value: String?): Pair<Float, Float>? {
    val match = iso6709Pattern.find(value?.trim() ?: return null) ?: return null
    val latitude = match.groupValues[1].toFloatOrNull() ?: return null
    val longitude = match.groupValues[2].toFloatOrNull() ?: return null
    if (latitude < -90f || latitude > 90f || longitude < -180f || longitude > 180f) return null
    return Pair(latitude, longitude)
}
