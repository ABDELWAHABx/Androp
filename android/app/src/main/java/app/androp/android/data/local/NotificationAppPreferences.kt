package app.androp.android.data.local

import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import app.androp.android.domain.model.NotificationApp

/** Encoding for the existing per-app schema; never clears other app_* settings such as pause. */
internal object NotificationAppPreferences {
    private val packageName = Regex("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+")
    fun read(preferences: Preferences): List<NotificationApp> = packages(preferences).map { pkg ->
        NotificationApp(
            packageName = pkg,
            appName = preferences[stringPreferencesKey("app_${pkg}_name")] ?: pkg,
            isEnabled = preferences[booleanPreferencesKey("app_${pkg}_enabled")] != false,
            isSystemApp = preferences[booleanPreferencesKey("app_${pkg}_system")] == true,
            lastUpdated = preferences[stringPreferencesKey("app_${pkg}_updated")]?.toLongOrNull() ?: 0L
        )
    }.sortedBy { it.appName }

    fun write(preferences: MutablePreferences, apps: List<NotificationApp>) {
        val retained = apps.mapTo(mutableSetOf()) { it.packageName }
        // Delete only removed packages' exact keys. app_paused shares the prefix,
        // so removing every app_* key would unexpectedly resume synchronization.
        for (pkg in packages(preferences) - retained) {
            preferences.remove(booleanPreferencesKey("app_${pkg}_enabled"))
            preferences.remove(stringPreferencesKey("app_${pkg}_name"))
            preferences.remove(booleanPreferencesKey("app_${pkg}_system"))
            preferences.remove(stringPreferencesKey("app_${pkg}_updated"))
        }
        for (app in apps) {
            val pkg = app.packageName
            preferences[booleanPreferencesKey("app_${pkg}_enabled")] = app.isEnabled
            preferences[stringPreferencesKey("app_${pkg}_name")] = app.appName
            preferences[booleanPreferencesKey("app_${pkg}_system")] = app.isSystemApp
            preferences[stringPreferencesKey("app_${pkg}_updated")] = app.lastUpdated.toString()
        }
    }

    private fun packages(preferences: Preferences): Set<String> = preferences.asMap().keys
        .mapNotNull { key ->
            key.name.takeIf { it.startsWith("app_") && it.endsWith("_enabled") }
                ?.removePrefix("app_")?.removeSuffix("_enabled")
                ?.takeIf { it == "android" || packageName.matches(it) }
        }.toSet()
}
