package app.androp.android.utils

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AppNavigationTest {
    @Test fun remoteActionCannotOpenSettingsWhenDisconnected() {
        assertEquals(0, AppNavigation.page(AppNavigation.REMOTE, connected = false))
        assertEquals(1, AppNavigation.page(AppNavigation.REMOTE, connected = true))
    }

    @Test fun filesAlwaysOpenDashboardAndSettingsRespectTabCount() {
        assertEquals(0, AppNavigation.page(AppNavigation.FILES, connected = false))
        assertEquals(0, AppNavigation.page(AppNavigation.FILES, connected = true))
        assertEquals(1, AppNavigation.page(AppNavigation.SETTINGS, connected = false))
        assertEquals(3, AppNavigation.page(AppNavigation.SETTINGS, connected = true))
    }

    @Test fun unknownExternalDestinationsAreIgnored() {
        assertNull(AppNavigation.destination("arbitrary", null))
        assertEquals(AppNavigation.REMOTE,
            AppNavigation.destination(null, "app.androp.android.ACTION_REMOTE"))
    }
}
