package com.bestcatscience.icreadsample

import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.bestcatscience.icreadkit.CardReadException
import com.bestcatscience.icreadkit.CardReader
import java.util.concurrent.Executors

/**
 * The host app. It shows how an Android app consumes the kit: check availability, enable reader
 * mode only while waiting, read on the reader-mode thread, and word every reason itself.
 */
class MainActivity : ComponentActivity(), NfcAdapter.ReaderCallback {
    private lateinit var state: ReaderState
    private val reader by lazy { CardReader { event -> runOnUiThread { state.record(event) } } }
    private val demoExecutor = Executors.newSingleThreadExecutor()
    private var session: CardReader.Session? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        state = ReaderState(CardReader.availability(this))
        setContent {
            ReaderScreen(
                state = state,
                onRead = ::startReading,
                onCancel = ::cancelReading,
                onOpenNfcSettings = { startActivity(Intent(Settings.ACTION_NFC_SETTINGS)) },
            )
        }
    }

    override fun onPause() {
        super.onPause()
        // Leaving the screen while waiting is an abandoned read.
        if (state.phase == ReaderState.Phase.Waiting) cancelReading()
    }

    private fun startReading() {
        state.phase = ReaderState.Phase.Waiting
        if (state.usesDemoCards) {
            val demo = reader.startDemoSession().also { session = it }
            val card = state.demoCard
            demoExecutor.execute { finish { demo.readDemo(card) } }
        } else {
            session = reader.startSession()
            NfcAdapter.getDefaultAdapter(this)?.enableReaderMode(this, this, CardReader.READER_MODE_FLAGS, null)
        }
    }

    /** Reader mode delivers the tag on a binder thread, where blocking on the card is fine. */
    override fun onTagDiscovered(tag: Tag) {
        val current = session ?: return
        finish { current.read(tag) }
    }

    private fun cancelReading() {
        session?.cancel()
        session = null
        NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this)
        state.phase = ReaderState.Phase.Idle
    }

    private fun finish(read: () -> com.bestcatscience.icreadkit.CertificateSummary) {
        val phase = try {
            ReaderState.Phase.Read(read())
        } catch (error: CardReadException) {
            ReaderState.Phase.Failed(error.reason, error.statusWord)
        }
        runOnUiThread {
            session = null
            if (!state.usesDemoCards) NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this)
            state.phase = phase
        }
    }

    override fun onDestroy() {
        demoExecutor.shutdown()
        super.onDestroy()
    }
}
