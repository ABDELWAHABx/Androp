package app.androp.android.utils

import app.androp.android.domain.model.NotificationApp

object AppSelectionPolicy {
    fun visible(apps: List<NotificationApp>, query: String, showSystemApps: Boolean): List<NotificationApp> {
        val search = query.trim()
        return apps.filter {
            (it.appName.contains(search, ignoreCase = true) || it.packageName.contains(search, ignoreCase = true)) &&
                (!it.isSystemApp || showSystemApps || it.isEnabled)
        }.distinctBy { it.packageName }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.appName })
    }

    fun setEnabled(apps: List<NotificationApp>, packages: Set<String>, enabled: Boolean): List<NotificationApp> =
        apps.map { if (it.packageName in packages) it.copy(isEnabled = enabled) else it }
}
