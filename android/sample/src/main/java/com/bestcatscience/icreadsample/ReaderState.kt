package com.bestcatscience.icreadsample

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.bestcatscience.icreadkit.CardReadEvent
import com.bestcatscience.icreadkit.CardReadException
import com.bestcatscience.icreadkit.CardReader
import com.bestcatscience.icreadkit.CertificateSummary
import com.bestcatscience.icreadkit.DemoCard

/** The screen state. Mirrors the iOS sample's ReaderModel so both apps behave the same. */
class ReaderState(val availability: CardReader.Availability) {
    sealed interface Phase {
        data object Idle : Phase
        data object Waiting : Phase
        data class Read(val summary: CertificateSummary) : Phase
        data class Failed(val reason: CardReadException.Reason, val statusWord: Int) : Phase
    }

    /** Counts for the read funnel, kept only on this device. */
    data class Funnel(val started: Int = 0, val cardDetected: Int = 0, val read: Int = 0) {
        val abandonRate: Double? get() = if (started == 0) null else (started - read).toDouble() / started
    }

    /** An emulator has no NFC hardware, so it shows demo cards and every screen can still be tested. */
    val usesDemoCards = availability == CardReader.Availability.NO_NFC_HARDWARE

    var phase: Phase by mutableStateOf(Phase.Idle)
    var demoCard: DemoCard by mutableStateOf(DemoCard.VALID)
    var funnel: Funnel by mutableStateOf(Funnel())
    val events = mutableStateListOf<String>()

    val canRead: Boolean
        get() = phase != Phase.Waiting && (usesDemoCards || availability == CardReader.Availability.AVAILABLE)

    fun record(event: CardReadEvent) {
        events.add(0, describe(event))
        while (events.size > 6) events.removeAt(events.lastIndex)
        funnel = when {
            event.kind == CardReadEvent.Kind.STARTED -> funnel.copy(started = funnel.started + 1)
            event.kind == CardReadEvent.Kind.CARD_DETECTED && event.attempt == 1 -> funnel.copy(cardDetected = funnel.cardDetected + 1)
            event.kind == CardReadEvent.Kind.FINISHED && event.outcome == CardReadEvent.Outcome.READ -> funnel.copy(read = funnel.read + 1)
            else -> funnel
        }
    }

    companion object {
        fun describe(event: CardReadEvent): String = when (event.kind) {
            CardReadEvent.Kind.STARTED -> if (event.demo) "開始（デモ）" else "開始"
            CardReadEvent.Kind.CARD_DETECTED -> if (event.attempt == 1) "カード検出" else "カード再検出（${event.attempt} 回目）"
            CardReadEvent.Kind.FINISHED -> {
                val outcome = when (event.outcome) {
                    CardReadEvent.Outcome.READ -> if (event.validity == CertificateSummary.Validity.VALID) "読み取り（有効）" else "読み取り（有効でない）"
                    CardReadEvent.Outcome.CANCELLED -> "中止"
                    else -> "失敗・${event.failure}"
                }
                "終了：$outcome（${event.durationMillis}ms）"
            }
            else -> "不明なイベント"
        }

        /** The kit returns reasons; the host app decides the words. */
        fun message(reason: CardReadException.Reason, statusWord: Int = 0): String = when (reason) {
            CardReadException.Reason.NO_NFC_HARDWARE -> "この端末では NFC でカードを読めません。"
            CardReadException.Reason.NFC_DISABLED -> "NFC がオフになっています。設定でオンにしてください。"
            CardReadException.Reason.CANCELLED -> "読み取りを中止しました。"
            CardReadException.Reason.CONNECTION_LOST -> "読み取り中にカードが離れました。動かさずにもう一度当ててください。"
            CardReadException.Reason.UNSUPPORTED_CARD -> "このカードには対応していません。マイナンバーカードを当ててください。"
            CardReadException.Reason.CARD_REJECTED -> "カードが読み取りを受け付けませんでした（%04X）。".format(statusWord)
            CardReadException.Reason.MALFORMED_CERTIFICATE -> "カードの証明書を読み取れませんでした。"
            else -> "読み取れませんでした。"
        }

        fun title(card: DemoCard): String = when (card) {
            DemoCard.VALID -> "有効な証明書のカード"
            DemoCard.EXPIRED -> "証明書の期限が切れたカード"
            DemoCard.OTHER_CARD -> "マイナンバーカード以外のカード"
            DemoCard.CONNECTION_LOST -> "読み取り中に離れるカード"
            else -> card.id
        }

        fun title(validity: CertificateSummary.Validity): String = when (validity) {
            CertificateSummary.Validity.VALID -> "有効"
            CertificateSummary.Validity.EXPIRED -> "期限切れ"
            CertificateSummary.Validity.NOT_YET_VALID -> "まだ有効ではありません"
            else -> "不明"
        }
    }
}
