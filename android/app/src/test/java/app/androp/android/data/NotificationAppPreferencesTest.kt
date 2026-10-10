package app.androp.android.data

import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.mutablePreferencesOf
import androidx.datastore.preferences.core.stringPreferencesKey
import app.androp.android.data.local.NotificationAppPreferences
import app.androp.android.domain.model.NotificationApp
import org.junit.Assert.*
import org.junit.Test

class NotificationAppPreferencesTest {
    @Test fun replacingAppsPreservesPauseAndUnrelatedPreferences() {
        val paused = booleanPreferencesKey("app_paused")
        val custom = stringPreferencesKey("app_custom_preference")
        val feature = booleanPreferencesKey("app_feature_enabled")
        val preferences = mutablePreferencesOf(paused to true, custom to "keep", feature to true)
        NotificationAppPreferences.write(preferences, listOf(NotificationApp("com.old", "Old")))
        NotificationAppPreferences.write(preferences, listOf(NotificationApp("com.new", "New", isEnabled = false)))
        assertEquals(true, preferences[paused])
        assertEquals("keep", preferences[custom])
        assertEquals(true, preferences[feature])
        assertNull(preferences[booleanPreferencesKey("app_com.old_enabled")])
        assertNull(preferences[stringPreferencesKey("app_com.old_name")])
        assertEquals(listOf("com.new"), NotificationAppPreferences.read(preferences).map { it.packageName })
        assertFalse(NotificationAppPreferences.read(preferences).single().isEnabled)
    }

    @Test fun clearingAppsDoesNotResumePausedApp() {
        val paused = booleanPreferencesKey("app_paused")
        val preferences = mutablePreferencesOf(paused to true)
        NotificationAppPreferences.write(preferences, listOf(NotificationApp("android", "Android", isSystemApp = true)))
        NotificationAppPreferences.write(preferences, emptyList())
        assertEquals(true, preferences[paused])
        assertTrue(NotificationAppPreferences.read(preferences).isEmpty())
    }

    @Test fun existingSchemaRoundTripsSettingsAndTimestamp() {
        val preferences = mutablePreferencesOf()
        val original = NotificationApp("com.example.player", "Player", false, isSystemApp = true, lastUpdated = 123L)
        NotificationAppPreferences.write(preferences, listOf(original))
        assertEquals(original, NotificationAppPreferences.read(preferences).single())
    }

    @Test fun legacyMalformedTimestampDoesNotCrash() {
        val preferences = mutablePreferencesOf(
            booleanPreferencesKey("app_com.example_enabled") to false,
            stringPreferencesKey("app_com.example_updated") to "invalid"
        )
        val app = NotificationAppPreferences.read(preferences).single()
        assertEquals("com.example", app.appName)
        assertEquals(0L, app.lastUpdated)
        assertFalse(app.isEnabled)
    }
}
