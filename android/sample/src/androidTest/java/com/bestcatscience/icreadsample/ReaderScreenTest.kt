package com.bestcatscience.icreadsample

import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import org.junit.Rule
import org.junit.Test

/**
 * The Android counterpart of the iOS XCUITests. An emulator has no NFC hardware, so the app shows
 * demo cards and every result screen can be checked without a card.
 */
class ReaderScreenTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun read(card: String) {
        compose.onNodeWithTag("demo-card-$card").performClick()
        compose.onNodeWithTag("read-button").performClick()
        compose.waitUntil(10_000) {
            compose.onAllNodes(androidx.compose.ui.test.hasTestTag("result-validity")).fetchSemanticsNodes().isNotEmpty() ||
                compose.onAllNodes(androidx.compose.ui.test.hasTestTag("error-message")).fetchSemanticsNodes().isNotEmpty()
        }
    }

    @Test fun aValidCardShowsTheValidityPeriod() {
        read("valid")
        compose.onNodeWithTag("result-validity").assertTextEquals("有効")
        compose.onNodeWithTag("result-period").assertExists()
    }

    @Test fun anExpiredCardIsAResultNotAnError() {
        read("expired")
        compose.onNodeWithTag("result-validity").assertTextEquals("期限切れ")
        compose.onNodeWithTag("error-message").assertDoesNotExist()
    }

    @Test fun anotherKindOfCardIsExplained() {
        read("other-card")
        compose.onNodeWithTag("error-message").assertTextContains("対応していません", substring = true)
    }

    @Test fun theFunnelCountsAnAbandonedRead() {
        read("connection-lost")
        compose.onNodeWithTag("funnel-abandon-rate").performScrollTo().assertTextEquals("100%")
    }
}
