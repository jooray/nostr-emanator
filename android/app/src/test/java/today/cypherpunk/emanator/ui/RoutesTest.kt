package today.cypherpunk.emanator.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class RoutesTest {
    @Test
    fun subRoutesLightTheirBottomTab() {
        assertEquals(Routes.POSTS, Routes.tabOf(Routes.POST))
        assertEquals(Routes.POSTS, Routes.tabOf(Routes.COMPOSE))
        assertEquals(Routes.MESSAGES, Routes.tabOf(Routes.CONVERSATION))
        assertEquals(Routes.MORE, Routes.tabOf(Routes.ACCOUNT_EDIT))
        assertEquals(Routes.MORE, Routes.tabOf(Routes.DEVICES))
        assertEquals(Routes.DASHBOARD, Routes.tabOf(null))
    }

    @Test
    fun theFullRailLightsWhatMoreWouldHold() {
        assertEquals(Routes.COMPOSE, Routes.railItemOf(Routes.COMPOSE))
        assertEquals(Routes.ACCOUNTS, Routes.railItemOf(Routes.ACCOUNT_PROFILE))
        assertEquals(Routes.ACCOUNTS, Routes.railItemOf(Routes.PAIR))
        assertEquals(Routes.SETTINGS, Routes.railItemOf(Routes.MCP_TOKENS))
        assertEquals(Routes.BILLING, Routes.railItemOf(Routes.BILLING))
        assertEquals(Routes.POSTS, Routes.railItemOf(Routes.SCHEDULE))
        assertEquals(Routes.MESSAGES, Routes.railItemOf(Routes.CONVERSATION))
    }
}
