package com.bestcatscience.icreadsample

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import com.bestcatscience.icreadkit.CardReader
import com.bestcatscience.icreadkit.CertificateSummary
import com.bestcatscience.icreadkit.DemoCard
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * The same palette as the iOS sample: a grouped grey ground, white cards and the system blue,
 * so the two apps read as one product rather than a stock Material template.
 */
private val SampleColors = lightColorScheme(
    primary = Color(0xFF0A66D6),
    onPrimary = Color.White,
    background = Color(0xFFF2F2F7),
    surface = Color(0xFFF2F2F7),
    surfaceContainerHighest = Color.White,
    surfaceContainerHigh = Color.White,
    onSurface = Color(0xFF1C1C1E),
    onSurfaceVariant = Color(0xFF6C6C70),
)

private val day = DateTimeFormatter.ofPattern("yyyy年M月d日").withZone(ZoneId.systemDefault())

/**
 * The same screen as the iOS sample, with the same identifiers as test tags. Exposing test tags as
 * resource IDs lets one set of Maestro flows find the same elements on both platforms.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun ReaderScreen(state: ReaderState, onRead: () -> Unit, onCancel: () -> Unit, onOpenNfcSettings: () -> Unit) {
    MaterialTheme(colorScheme = SampleColors) {
        Surface(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
            Column(
                Modifier.safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("IC 証明書リーダー", style = MaterialTheme.typography.headlineMedium)
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("マイナンバーカードの利用者証明用電子証明書から、発行者と有効期限だけを読みます。")
                        Text("・暗証番号は使いません")
                        Text("・氏名・住所・生年月日は読みません")
                    }
                }

                if (state.usesDemoCards) {
                    DemoCards(state)
                } else if (state.availability == CardReader.Availability.NFC_DISABLED) {
                    Text(ReaderState.message(com.bestcatscience.icreadkit.CardReadException.Reason.NFC_DISABLED),
                        color = Color.Red, modifier = Modifier.testTag("availability-message"))
                    OutlinedButton(onClick = onOpenNfcSettings) { Text("NFC の設定を開く") }
                }

                if (state.phase == ReaderState.Phase.Waiting) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.padding(end = 12.dp))
                        Text(if (state.usesDemoCards) "読み取り中…" else "カードを端末の背面に当ててください")
                    }
                    OutlinedButton(onClick = onCancel, modifier = Modifier.testTag("cancel-button")) { Text("中止") }
                } else {
                    Button(onClick = onRead, enabled = state.canRead, modifier = Modifier.fillMaxWidth().testTag("read-button")) {
                        Text("カードを読む")
                    }
                }

                Result(state.phase)
                Measurement(state)
            }
        }
    }
}

@Composable
private fun DemoCards(state: ReaderState) {
    Text("デモ用の架空のカード", style = MaterialTheme.typography.titleSmall)
    Card(Modifier.fillMaxWidth()) {
        DemoCard.values().forEach { card ->
            Row(
                Modifier.fillMaxWidth().clickable { state.demoCard = card }.padding(16.dp).testTag("demo-card-${card.id}"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(ReaderState.title(card), Modifier.weight(1f))
                if (state.demoCard == card) Text("✓")
            }
        }
    }
    Text("この端末では NFC が使えないため、架空のカードで動かしています。実際のカードは NFC のある端末で読めます。",
        style = MaterialTheme.typography.bodySmall)
}

@Composable
private fun Result(phase: ReaderState.Phase) {
    when (phase) {
        is ReaderState.Phase.Read -> Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("読み取った証明書", style = MaterialTheme.typography.titleSmall)
                val validity = phase.summary.validity()
                Labeled("状態") {
                    Text(ReaderState.title(validity),
                        color = if (validity == CertificateSummary.Validity.VALID) Color(0xFF1B7F3B) else Color.Red,
                        modifier = Modifier.testTag("result-validity"))
                }
                Labeled("有効期間") {
                    Text("${day.format(phase.summary.notBefore)} 〜 ${day.format(phase.summary.notAfter)}",
                        modifier = Modifier.testTag("result-period"))
                }
                Labeled("発行者") { Text(phase.summary.issuer) }
            }
        }
        is ReaderState.Phase.Failed -> Text(ReaderState.message(phase.reason, phase.statusWord),
            color = Color.Red, modifier = Modifier.testTag("error-message"))
        else -> Unit
    }
}

@Composable
private fun Measurement(state: ReaderState) {
    val funnel = state.funnel
    if (funnel.started == 0) return
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("計測イベント", style = MaterialTheme.typography.titleSmall)
            Labeled("開始") { Text("${funnel.started}") }
            Labeled("カード検出") { Text("${funnel.cardDetected}") }
            Labeled("読み取り") { Text("${funnel.read}") }
            funnel.abandonRate?.let { rate ->
                Labeled("離脱率") { Text("${Math.round(rate * 100)}%", Modifier.testTag("funnel-abandon-rate")) }
            }
            state.events.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
            Text("カードのデータは含みません。実際のアプリでは、このイベントを監視基盤に送ります。",
                style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun Labeled(label: String, value: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.width(96.dp))
        Spacer(Modifier.weight(1f))
        value()
    }
}
