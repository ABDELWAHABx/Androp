package app.androp.android.utils

/** Stable notification/shortcut destinations, independent of the current tab count. */
object AppNavigation {
    const val EXTRA_DESTINATION = "androp_destination"
    const val DASHBOARD = "dashboard"
    const val REMOTE = "remote"
    const val FILES = "files"
    const val SETTINGS = "settings"
    const val CLIPBOARD = "clipboard"

    fun destination(requested: String?, action: String?): String? = when {
        requested in setOf(DASHBOARD, REMOTE, FILES, SETTINGS, CLIPBOARD) -> requested
        action == "app.androp.android.ACTION_REMOTE" -> REMOTE
        else -> null
    }

    fun page(destination: String, connected: Boolean): Int = when (destination) {
        REMOTE -> if (connected) 1 else 0
        CLIPBOARD -> if (connected) 2 else 0
        SETTINGS -> if (connected) 3 else 1
        else -> 0
    }
}
