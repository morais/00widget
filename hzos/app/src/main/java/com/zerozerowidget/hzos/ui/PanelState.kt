package com.zerozerowidget.hzos.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.zerozerowidget.hzos.data.ConnectionStore

// What panels read from the app's stores, collected only while the panel
// is started, with each default written once. Panels call these rather
// than collecting the flows themselves (audit M4 / P7).

@Composable
fun PanelPrefs.cardAlphaState(): State<Float> = cardAlpha.collectAsStateWithLifecycle(PanelPrefs.DEFAULT_CARD_ALPHA)

@Composable
fun PanelPrefs.hideSampleIndicatorsState(): State<Boolean> = hideSampleIndicators.collectAsStateWithLifecycle(false)

@Composable
fun PanelPrefs.showDummyAccountDataState(): State<Boolean> = showDummyAccountData.collectAsStateWithLifecycle(false)

/** Signed out until DataStore's first emission, which is local and fast. */
@Composable
fun ConnectionStore.connectionState(): State<ConnectionStore.Connection> = connection.collectAsStateWithLifecycle(ConnectionStore.Connection("", ""))
