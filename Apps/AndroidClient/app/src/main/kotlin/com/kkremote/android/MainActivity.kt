package com.kkremote.android

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import com.kkremote.android.ui.KKRemoteScreen
import com.kkremote.android.ui.WorkspaceViewModel
import com.kkremote.android.ui.theme.KKRemoteTheme

class MainActivity : ComponentActivity() {

    private val viewModel: WorkspaceViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        consumePairingIntent(intent)

        setContent {
            KKRemoteTheme {
                KKRemoteScreen(viewModel = viewModel)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumePairingIntent(intent)
    }

    private fun consumePairingIntent(incoming: Intent?) {
        if (incoming == null) return
        val extraUrl = incoming.getStringExtra("pair_url")?.trim()
        val dataUrl = incoming.dataString?.trim()
        val candidate = extraUrl?.takeIf { it.isNotEmpty() } ?: dataUrl?.takeIf { it.isNotEmpty() }
        if (!candidate.isNullOrEmpty()) {
            viewModel.importPairingLink(candidate)
            incoming.removeExtra("pair_url")
        }
    }
}
