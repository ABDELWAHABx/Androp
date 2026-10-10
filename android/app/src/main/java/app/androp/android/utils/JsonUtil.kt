package app.androp.android.utils

object JsonUtil {

    /**
     * Ensures JSON string is a single line by removing all newlines and extra whitespace
     */
    fun toSingleLine(json: String): String {
        // Only remove formatting outside strings; notification text may contain repeated spaces.
        var inString = false
        var escaped = false
        return buildString(json.length) {
            for (character in json) {
                if (inString) {
                    append(character)
                    if (escaped) escaped = false
                    else if (character == '\\') escaped = true
                    else if (character == '"') inString = false
                } else if (character == '"') {
                    inString = true
                    append(character)
                } else if (!character.isWhitespace()) append(character)
            }
        }
    }

    /**
     * Creates a single-line JSON string for device info
     */
    fun createDeviceInfoJson(
        name: String,
        ipAddress: String,
        port: Int,
        version: String,
        targetIpAddress: String? = null
    ): String {
        val targetIpJson =
            if (targetIpAddress != null) """, "targetIpAddress": "${escape(targetIpAddress)}" """ else ""
        return """{"type":"device","data":{"name":"${escape(name)}","ipAddress":"${escape(ipAddress)}","port":$port,"version":"${escape(version)}","adbPorts":[]$targetIpJson}}"""
    }

    /**
     * Creates a single-line JSON string for device info with ADB ports
     */
    fun createDeviceInfoJson(
        id: String,
        name: String,
        ipAddress: String,
        port: Int,
        version: String,
        adbPorts: List<String>,
        targetIpAddress: String? = null
    ): String {
        val portsJson = adbPorts.joinToString(",") { "\"${escape(it)}\"" }
        val targetIpJson =
            if (targetIpAddress != null) """, "targetIpAddress": "${escape(targetIpAddress)}" """ else ""
        return """{"type":"device","data":{"id":"${escape(id)}","name":"${escape(name)}","ipAddress":"${escape(ipAddress)}","port":$port,"version":"${escape(version)}","adbPorts":[$portsJson]$targetIpJson}}"""
    }

    /**
     * Creates a single-line JSON string for device info with wallpaper
     */
    fun createDeviceInfoJson(
        id: String,
        name: String,
        ipAddress: String,
        port: Int,
        version: String,
        wallpaperBase64: String?,
        adbPorts: List<String>,
        bleAuthToken: String? = null,
        targetIpAddress: String? = null
    ): String {
        val wallpaperJson = if (wallpaperBase64 != null) {
            ""","wallpaper":"${escape(wallpaperBase64)}""""
        } else {
            ""
        }
        val bleTokenJson = if (bleAuthToken != null) {
            ""","bleAuthToken":"${escape(bleAuthToken)}""""
        } else {
            ""
        }
        val portsJson = adbPorts.joinToString(",") { "\"${escape(it)}\"" }
        val targetIpJson =
            if (targetIpAddress != null) """, "targetIpAddress": "${escape(targetIpAddress)}" """ else ""
        return """{"type":"device","data":{"id":"${escape(id)}","name":"${escape(name)}","ipAddress":"${escape(ipAddress)}","port":$port,"version":"${escape(version)}","adbPorts":[$portsJson]$wallpaperJson$bleTokenJson$targetIpJson}}"""
    }

    /**
     * Creates a single-line JSON string for notifications with unique ID
     */
    fun createNotificationJson(
        id: String,
        title: String,
        body: String,
        app: String,
        packageName: String
    ): String {
        return """{"type":"notification","data":{"id":"${escape(id)}","title":"${escape(title)}","body":"${escape(body)}","app":"${escape(app)}","package":"${escape(packageName)}"}}"""
    }

    /**
     * Creates a single-line JSON string for notifications with actions included.
     * actions: list of objects { name: String, type: "button" | "reply" }
     */
    fun createNotificationJson(
        id: String,
        title: String,
        body: String,
        app: String,
        packageName: String,
        priority: String = "alerting",
        actions: List<Pair<String, String>>,
        progress: Int? = null,
        progressMax: Int? = null,
        progressIndeterminate: Boolean? = null,
        ongoing: Boolean? = null
    ): String {
        val actionsJson = if (actions.isNotEmpty()) {
            val items = actions.joinToString(",") { (name, type) ->
                """{"name":"${escape(name)}","type":"${escape(type)}"}"""
            }
            ",\"actions\":[${items}]"
        } else {
            ""
        }
        val progressJson = if (progress != null) ",\"progress\":$progress" else ""
        val progressMaxJson = if (progressMax != null) ",\"progressMax\":$progressMax" else ""
        val progressIndeterminateJson = if (progressIndeterminate != null) ",\"progressIndeterminate\":$progressIndeterminate" else ""
        val ongoingJson = if (ongoing != null) ",\"ongoing\":$ongoing" else ""
        return """{"type":"notification","data":{"id":"${escape(id)}","title":"${escape(title)}","body":"${
            escape(
                body
            )
        }","app":"${escape(app)}","package":"${escape(packageName)}","priority":"${escape(priority)}"$actionsJson$progressJson$progressMaxJson$progressIndeterminateJson$ongoingJson}}"""
    }

    /**
     * Creates a one-line JSON for Android->Mac notification state updates (e.g., dismissals).
     * If action is not provided, defaults to "dismiss" when dismissed=true.
     */
    fun createNotificationUpdateJson(
        id: String,
        dismissed: Boolean = true,
        action: String? = null
    ): String {
        val safeAction = action ?: if (dismissed) "dismiss" else null
        val actionPart = safeAction?.let { ",\"action\":\"${escape(it)}\"" } ?: ""
        return """{"type":"notificationUpdate","data":{"id":"${escape(id)}","dismissed":$dismissed$actionPart}}"""
    }

    private fun escape(value: String): String {
        return buildString(value.length) {
            for (character in value) {
                when (character) {
                    '\\' -> append("\\\\")
                    '"' -> append("\\\"")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    '\b' -> append("\\b")
                    '\u000C' -> append("\\f")
                    else -> if (character < ' ') {
                        append("\\u")
                        append(character.code.toString(16).padStart(4, '0'))
                    } else append(character)
                }
            }
        }
    }

    /**
     * Creates a single-line JSON string for device status with media playing state
     */
    fun createDeviceStatusJson(
        batteryLevel: Int,
        isCharging: Boolean,
        isPaired: Boolean,
        isPlaying: Boolean,
        title: String,
        artist: String,
        volume: Int,
        isMuted: Boolean,
        albumArt: String?,
        albumArtLite: String? = null,
        duration: Long = 0L,
        position: Long = 0L,
        positionTimestamp: Long = 0L,
        isBuffering: Boolean = false,
        likeStatus: String
    ): String {
        val albumArtJson = if (albumArt != null) ",\"albumArt\":\"${escape(albumArt)}\"" else ""
        val albumArtLiteJson =
            if (albumArtLite != null) ",\"albumArtLite\":\"${escape(albumArtLite)}\"" else ""
        return """{"type":"status","data":{"battery":{"level":$batteryLevel,"isCharging":$isCharging},"isPaired":$isPaired,"music":{"isPlaying":$isPlaying,"title":"${escape(title)}","artist":"${escape(artist)}","volume":$volume,"isMuted":$isMuted$albumArtJson$albumArtLiteJson,"duration":$duration,"position":$position,"positionTimestamp":$positionTimestamp,"isBuffering":$isBuffering,"likeStatus":"${escape(likeStatus)}"}}}"""
    }

    /**
     * Creates a response JSON for notification dismissal result
     */
    fun createNotificationDismissalResponse(
        id: String,
        success: Boolean,
        message: String = ""
    ): String {
        return """{"type":"dismissalResponse","data":{"id":"${escape(id)}","success":$success,"message":"${escape(message)}"}}"""
    }

    /**
     * Creates a response JSON for notification action result
     */
    fun createNotificationActionResponse(
        id: String,
        actionName: String,
        success: Boolean,
        message: String = ""
    ): String {
        return """{"type":"notificationActionResponse","data":{"id":"${escape(id)}","action":"${
            escape(
                actionName
            )
        }","success":$success,"message":"${escape(message)}"}}"""
    }

    /**
     * Creates a response JSON for media control result
     */
    fun createMediaControlResponse(action: String, success: Boolean, message: String = ""): String {
        return """{"type":"mediaControlResponse","data":{"action":"${escape(action)}","success":$success,"message":"${escape(message)}"}}"""
    }

    /**
     * Creates a response JSON for volume control result
     */
    fun createVolumeControlResponse(
        action: String,
        success: Boolean,
        message: String = ""
    ): String {
        return """{"type":"volumeControlResponse","data":{"action":"${escape(action)}","success":$success,"message":"${escape(message)}"}}"""
    }

    /**
     * Creates a JSON string for app icons
     */
    fun createAppIconsJson(
        apps: List<app.androp.android.domain.model.NotificationApp>,
        iconMap: Map<String, String>
    ): String {
        val appEntries = apps.joinToString(",") { app ->
            val iconData = iconMap[app.packageName] ?: ""
            """
            "${escape(app.packageName)}": {
                "name": "${escape(app.appName)}",
                "icon": "${escape(iconData)}",
                "listening": ${app.isEnabled},
                "systemApp": ${app.isSystemApp}
            }
            """.trimIndent()
        }
        return """{"type":"appIcons","data":{ $appEntries }}"""
    }

    /**
     * Creates a JSON string for clipboard updates
     */
    fun createClipboardUpdateJson(text: String): String {
        val escapedText = escape(text)
        return """{"type":"clipboardUpdate","data":{"text":"$escapedText"}}"""
    }

    /**
     * Creates a response JSON for app notification toggle result
     */
    fun createToggleAppNotificationResponse(
        packageName: String,
        success: Boolean,
        newState: Boolean,
        message: String = ""
    ): String {
        return """{"type":"toggleAppNotifResponse","data":{"package":"${escape(packageName)}","success":$success,"newState":$newState,"message":"${escape(message)}"}}"""
    }

    /**
     * Creates a response JSON for toggleNowPlaying command
     */
    fun createToggleNowPlayingResponse(
        success: Boolean,
        newState: Boolean?,
        message: String = ""
    ): String {
        val statePart = newState?.let { ",\"state\":$it" } ?: ""
        return """{"type":"toggleNowPlayingResponse","data":{"success":$success$statePart,"message":"${
            escape(
                message
            )
        }"}}"""
    }
}
