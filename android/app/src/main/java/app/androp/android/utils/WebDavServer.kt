package app.androp.android.utils

import android.content.Context
import android.os.Environment
import android.util.Log
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.encodeURLPathPart
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.call
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.path
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.response.respondFile
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.head
import io.ktor.server.routing.method
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.ServerSocket
import java.net.URLDecoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class WebDavServer(private val context: Context) {
    private var engine: ApplicationEngine? = null
    private val port = 9081
    private val TAG = "WebDavServer"

    private val storageRoot = Environment.getExternalStorageDirectory()

    @Synchronized
    fun start() {
        if (BackgroundWorkController.isPaused) return
        if (engine != null) {
            Log.d(TAG, "WebDAV server already initialized")
            return
        }

        if (!isPortAvailable(port)) {
            Log.e(TAG, "WebDAV server cannot start: Port $port is already in use")
            return
        }

        try {
            engine = embeddedServer(CIO, port = port, host = "0.0.0.0") {
                install(StatusPages) {
                    exception<Throwable> { call, cause ->
                        if (cause is kotlinx.coroutines.CancellationException) throw cause
                        Log.e(TAG, "Unhandled exception in route", cause)
                        call.respond(HttpStatusCode.InternalServerError, "Internal Server Error")
                    }
                }

                routing {
                    // Catch-all: matches any path including root
                    route("{...}") {
                        method(HttpMethod.parse("PROPFIND")) {
                            handle { withContext(Dispatchers.IO) { handlePropfind(call) } }
                        }
                        get { withContext(Dispatchers.IO) { handleGet(call) } }
                        head { withContext(Dispatchers.IO) { handleHead(call) } }
                        method(HttpMethod.Options) {
                            handle {
                                call.response.header("Allow", "GET, HEAD, OPTIONS, PROPFIND")
                                call.response.header("DAV", "1, 2")
                                call.respond(HttpStatusCode.OK)
                            }
                        }
                    }
                }
            }
            engine?.start(wait = false)
            Log.i(TAG, "WebDAV server started on port $port")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start WebDAV server on port $port", e)
            runCatching { engine?.stop(0, 1000) }
            engine = null
        }
    }

    private fun isPortAvailable(port: Int): Boolean {
        return try {
            ServerSocket(port).use { true }
        } catch (e: Exception) {
            false
        }
    }

    @Synchronized
    fun stop() {
        try {
            engine?.stop(500, 1000)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping WebDAV server", e)
        } finally {
            engine = null
            Log.i(TAG, "WebDAV server stopped")
        }
    }

    /**
     * Extracts the filesystem-relative path from the request URI.
     * URL-decodes the path and strips the leading slash so it can be
     * joined with storageRoot via File(storageRoot, relativePath).
     * Trailing slashes are removed before file resolution.
     */
    private fun resolveRequestPath(call: ApplicationCall): String {
        val raw = call.request.path() // e.g. "/", "/DCIM/", "/DCIM/Camera/IMG_001.jpg"
        val decoded = URLDecoder.decode(raw.replace("+", "%2B"), "UTF-8")
        return decoded.trimStart('/').trimEnd('/')
    }

    private suspend fun ensureFileAccess(call: ApplicationCall): Boolean {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
            call.respond(HttpStatusCode.Forbidden,
                "Enable File Access in androp on your phone and allow All files access in Android Settings to browse storage. Receiving files in Downloads does not need this permission.")
            return false
        }
        return true
    }

    private suspend fun handlePropfind(call: ApplicationCall) {
        if (!ensureFileAccess(call)) return
        val relativePath = resolveRequestPath(call)
        val file = StoragePathResolver.resolve(storageRoot, relativePath)
        if (file == null) {
            call.respond(HttpStatusCode.Forbidden)
            return
        }

        Log.d(TAG, "PROPFIND: raw=${call.request.path()} -> resolved=${file.absolutePath}")

        if (!file.exists()) {
            Log.w(TAG, "PROPFIND 404: ${file.absolutePath}")
            call.respond(HttpStatusCode.NotFound)
            return
        }

        val depth = call.request.headers["Depth"] ?: "1"
        val xml = buildPropfindXml(file, relativePath, depth)

        call.respondText(
            xml,
            ContentType.Text.Xml.withParameter("charset", "utf-8"),
            HttpStatusCode.MultiStatus
        )
    }

    private fun buildPropfindXml(file: File, relativePath: String, depth: String): String {
        val sb = StringBuilder()
        sb.append("<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n")
        sb.append("<d:multistatus xmlns:d=\"DAV:\">\n")

        val dateFormat = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss z", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("GMT")
        }
        appendFileEntry(sb, file, relativePath, dateFormat)

        if (file.isDirectory && depth != "0") {
            file.listFiles()
                ?.filter { !it.name.startsWith(".") }
                ?.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
                ?.forEach { child ->
                    val childRelPath =
                        if (relativePath.isEmpty()) child.name else "$relativePath/${child.name}"
                    appendFileEntry(sb, child, childRelPath, dateFormat)
                }
        }

        sb.append("</d:multistatus>")
        return sb.toString()
    }

    private fun appendFileEntry(sb: StringBuilder, file: File, relativePath: String, dateFormat: SimpleDateFormat) {
        val displayName = if (relativePath.isEmpty()) "Android" else file.name

        // Build the href: each path segment is percent-encoded individually,
        // but the "/" separators are preserved. Root is always "/".
        val href = if (relativePath.isEmpty()) {
            "/"
        } else {
            val encodedSegments = relativePath.split("/").joinToString("/") { segment ->
                segment.encodeURLPathPart()
            }
            // Directories must have trailing slash for WebDAV clients to recognise them
            if (file.isDirectory) "/$encodedSegments/" else "/$encodedSegments"
        }

        val lastModified = dateFormat.format(Date(file.lastModified()))

        sb.append("  <d:response>\n")
        sb.append("    <d:href>${xmlEscape(href)}</d:href>\n")
        sb.append("    <d:propstat>\n")
        sb.append("      <d:prop>\n")
        sb.append("        <d:displayname>${xmlEscape(displayName)}</d:displayname>\n")
        if (file.isDirectory) {
            sb.append("        <d:resourcetype><d:collection/></d:resourcetype>\n")
        } else {
            sb.append("        <d:resourcetype/>\n")
            sb.append("        <d:getcontentlength>${file.length()}</d:getcontentlength>\n")
            val contentType = java.net.URLConnection.guessContentTypeFromName(file.name)
                ?: "application/octet-stream"
            sb.append("        <d:getcontenttype>$contentType</d:getcontenttype>\n")
        }
        sb.append("        <d:getlastmodified>$lastModified</d:getlastmodified>\n")
        sb.append("      </d:prop>\n")
        sb.append("      <d:status>HTTP/1.1 200 OK</d:status>\n")
        sb.append("    </d:propstat>\n")
        sb.append("  </d:response>\n")
    }

    private fun xmlEscape(value: String): String = value.replace("&", "&amp;")
        .replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;")

    private suspend fun handleGet(call: ApplicationCall) {
        if (!ensureFileAccess(call)) return
        val relativePath = resolveRequestPath(call)
        val file = StoragePathResolver.resolve(storageRoot, relativePath)
        if (file == null) {
            call.respond(HttpStatusCode.Forbidden)
            return
        }

        Log.d(TAG, "GET: raw=${call.request.path()} -> resolved=${file.absolutePath}")

        if (!file.exists()) {
            call.respond(HttpStatusCode.NotFound)
            return
        }

        if (file.isDirectory) {
            call.respond(HttpStatusCode.MethodNotAllowed, "Cannot GET a directory")
            return
        }

        call.respondFile(file)
    }

    private suspend fun handleHead(call: ApplicationCall) {
        if (!ensureFileAccess(call)) return
        val relativePath = resolveRequestPath(call)
        val file = StoragePathResolver.resolve(storageRoot, relativePath)
        if (file == null) {
            call.respond(HttpStatusCode.Forbidden)
            return
        }

        if (!file.exists()) {
            call.respond(HttpStatusCode.NotFound)
            return
        }

        if (!file.isDirectory) {
            call.response.header(HttpHeaders.ContentLength, file.length().toString())
            val contentType = java.net.URLConnection.guessContentTypeFromName(file.name)
                ?: "application/octet-stream"
            call.response.header(HttpHeaders.ContentType, contentType)
        }
        val rfc1123Format = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss z", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("GMT")
        }
        call.response.header(
            HttpHeaders.LastModified,
            rfc1123Format.format(Date(file.lastModified()))
        )
        call.respond(HttpStatusCode.OK)
    }
}
