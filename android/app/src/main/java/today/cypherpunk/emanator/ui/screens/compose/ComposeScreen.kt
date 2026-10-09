package today.cypherpunk.emanator.ui.screens.compose

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.navigation.NavHostController
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.Account
import today.cypherpunk.emanator.data.Billing
import today.cypherpunk.emanator.media.ShrinkRules
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.Chop
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.MediaStrip
import today.cypherpunk.emanator.ui.components.NoteBlock
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.components.imageUrls
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Times
import java.io.File

private val UPLOAD_TYPES = arrayOf("image/*", "video/*", "audio/*", "application/pdf")

@Composable
fun ComposeScreen(nav: NavHostController, accountId: Long?, postId: Long?, fromShare: Boolean) {
    val vm = appViewModel(key = "compose-$postId-$accountId-$fromShare") { ComposeViewModel(it, accountId, postId, fromShare) }
    val ui by vm.ui.collectAsState()
    val text by vm.text.collectAsState()
    val context = LocalContext.current
    val c = LocalConsole.current

    LaunchedEffect(vm) {
        vm.navigation.collect { event ->
            // Editing from a post's page: "Save draft" returns to that page
            // rather than stacking a second copy of it.
            val previous = nav.previousBackStackEntry?.destination?.route
            if (event is ComposeEvent.Open && previous == Routes.POST) {
                nav.popBackStack()
                return@collect
            }
            // Edited from the schedule screen: go back to it (it reloads the
            // text) instead of stacking a second schedule screen on top.
            if (previous == Routes.SCHEDULE) {
                if (event is ComposeEvent.Schedule) nav.popBackStack()
                else if (event is ComposeEvent.Open) nav.navigate(Routes.post(event.postId)) { popUpTo(Routes.SCHEDULE) { inclusive = true } }
                return@collect
            }
            val route = when (event) {
                is ComposeEvent.Schedule -> Routes.schedule(event.postId)
                is ComposeEvent.Open -> Routes.post(event.postId)
            }
            nav.navigate(route) { popUpTo(Routes.COMPOSE) { inclusive = true } }
        }
    }

    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(MAX_PICK)) { vm.attach(it) }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { vm.attach(it) }
    var captureUri by rememberSaveable { mutableStateOf<Uri?>(null) }
    val takePicture = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        captureUri?.let { if (ok) vm.attach(listOf(it)) }
    }

    ConsoleScaffold(
        title = stringResource(if (postId != null) R.string.compose_title_edit else R.string.compose_title_new),
        onBack = { nav.popBackStack() },
    ) { padding ->
        if (ui.loading) {
            Box(Modifier.padding(padding).fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Palette.amber, strokeWidth = 2.dp)
            }
            return@ConsoleScaffold
        }
        if (ui.accounts.isEmpty()) {
            Column(Modifier.padding(padding).padding(Gutter), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                ui.error?.let { AlarmBlock(it) }
                EmptyState(stringResource(R.string.compose_no_accounts))
                PrimaryButton(stringResource(R.string.compose_add_account), { nav.navigate(Routes.pair()) }, Modifier.fillMaxWidth())
            }
            return@ConsoleScaffold
        }

        Column(
            Modifier.padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(horizontal = Gutter, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            AccountPicker(ui.accounts, ui.account, enabled = !ui.editing, onSelect = vm::selectAccount)

            ui.account?.let { account ->
                if (!account.hasSigner) {
                    WaitBlock(stringResource(R.string.compose_no_signer, account.name)) {
                        SlugButton(stringResource(R.string.compose_pair_signer), { nav.navigate(Routes.pair(account.id)) }, tone = SlugTone.Wait)
                    }
                }
            }
            if (!ui.canEdit) AlarmBlock(stringResource(R.string.compose_cannot_edit))
            if (ui.restoredDraft) {
                NoteRow(stringResource(R.string.compose_restored_draft), vm::dismissRestored)
            }

            OutlinedTextField(
                value = text,
                onValueChange = vm::onTextChange,
                placeholder = { Text(stringResource(R.string.compose_placeholder), style = Type.body, color = c.muted) },
                textStyle = Type.body.copy(color = c.text),
                enabled = ui.canEdit,
                modifier = Modifier.fillMaxWidth().heightIn(min = 200.dp),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    pluralStringResource(R.plurals.compose_chars, text.text.length, text.text.length),
                    style = Type.mono, color = c.muted, modifier = Modifier.weight(1f),
                )
            }
            val images = remember(text.text) { imageUrls(text.text) }
            if (images.isNotEmpty()) MediaStrip(images)

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                SecondaryButton(stringResource(R.string.compose_attach_photos), {
                    pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                }, Modifier.weight(1f), enabled = ui.canEdit)
                SecondaryButton(stringResource(R.string.compose_attach_camera), {
                    val dir = File(context.cacheDir, "captures").apply { mkdirs() }
                    val file = File(dir, "photo-${System.currentTimeMillis()}.jpg")
                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                    captureUri = uri
                    takePicture.launch(uri)
                }, Modifier.weight(1f), enabled = ui.canEdit)
                SecondaryButton(stringResource(R.string.compose_attach_files), { pickFiles.launch(UPLOAD_TYPES) }, Modifier.weight(1f), enabled = ui.canEdit)
            }
            ui.uploads.forEach { line -> UploadStatus(line) { vm.dismissUpload(line.key) } }

            Rule()
            AiPanel(ui, text.text.isNotBlank(), vm, onBilling = { nav.navigate(Routes.BILLING) })
            Rule()

            ui.error?.let { AlarmBlock(it) }
            PrimaryButton(
                stringResource(if (ui.uploading) R.string.compose_waiting_upload else R.string.compose_save_schedule),
                { vm.save(toSchedule = true) },
                Modifier.fillMaxWidth(),
                enabled = ui.canEdit && !ui.uploading && text.text.isNotBlank() && ui.accountId != null,
                busy = ui.saving,
            )
            SecondaryButton(
                stringResource(R.string.compose_save_draft),
                { vm.save(toSchedule = false) },
                Modifier.fillMaxWidth(),
                enabled = ui.canEdit && !ui.uploading && !ui.saving && text.text.isNotBlank() && ui.accountId != null,
            )
        }
    }
}

@Composable
private fun AccountPicker(accounts: List<Account>, selected: Account?, enabled: Boolean, onSelect: (Long) -> Unit) {
    val c = LocalConsole.current
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().border(1.dp, c.rule)
                .then(if (enabled && accounts.size > 1) Modifier.clickable { open = true } else Modifier)
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Chop(selected?.mini(), 28.dp)
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.compose_posting_as).uppercase(), style = Type.slug, color = c.muted)
                Text(selected?.name ?: stringResource(R.string.compose_choose_account), style = Type.bodyDense, color = c.text)
            }
            if (enabled && accounts.size > 1) Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = c.legend)
        }
        DropdownMenu(open, onDismissRequest = { open = false }) {
            accounts.forEach { account ->
                DropdownMenuItem(
                    text = { Text(account.name, style = Type.bodyDense) },
                    leadingIcon = { Chop(account.mini(), 24.dp) },
                    onClick = { onSelect(account.id); open = false },
                )
            }
        }
    }
}

@Composable
private fun UploadStatus(line: UploadLine, onDismiss: () -> Unit) {
    val c = LocalConsole.current
    val phase = line.phase
    val message = when (phase) {
        UploadPhase.Shrinking -> stringResource(R.string.upload_shrinking, line.name)
        is UploadPhase.Encoding -> stringResource(R.string.upload_encoding, line.name, phase.percent)
        is UploadPhase.Shrunk -> stringResource(R.string.upload_shrunk, line.name, ShrinkRules.humanSize(phase.from), ShrinkRules.humanSize(phase.to))
        UploadPhase.Uploading -> "${line.name}: ${stringResource(R.string.upload_uploading)}"
        is UploadPhase.Step -> "${line.name}: ${phase.text}"
        is UploadPhase.Done -> if (phase.from != null && phase.to != null) {
            stringResource(R.string.upload_done_shrunk, line.name, ShrinkRules.humanSize(phase.from), ShrinkRules.humanSize(phase.to))
        } else stringResource(R.string.upload_done, line.name)
        is UploadPhase.TooLarge -> stringResource(R.string.upload_too_large, line.name, ShrinkRules.humanSize(phase.size), ShrinkRules.humanSize(phase.limit))
        UploadPhase.TimedOut -> "${line.name}: ${stringResource(R.string.upload_timed_out)}"
        is UploadPhase.Failed -> "${line.name}: ${phase.message?.takeIf { it.isNotBlank() } ?: stringResource(R.string.upload_failed)}"
    }
    val failed = phase is UploadPhase.Failed || phase is UploadPhase.TooLarge || phase is UploadPhase.TimedOut
    Row(
        Modifier.fillMaxWidth().then(if (failed) Modifier.background(c.alarmFill) else Modifier).padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (phase.inFlight) CircularProgressIndicator(Modifier.size(14.dp), color = Palette.amber, strokeWidth = 2.dp)
        Text(message, style = Type.small, color = if (failed) c.redText else c.legend, modifier = Modifier.weight(1f))
        if (!phase.inFlight) {
            IconButton(onClick = onDismiss) {
                Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.action_close), tint = c.muted)
            }
        }
    }
}

@Composable
private fun NoteRow(text: String, onDismiss: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        NoteBlock(text, Modifier.weight(1f))
        IconButton(onClick = onDismiss) {
            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.action_close), tint = LocalConsole.current.muted)
        }
    }
}

/** AI writing, as the web composer offers it: generate from a prompt, then refine. */
@Composable
private fun AiPanel(ui: ComposeUi, hasText: Boolean, vm: ComposeViewModel, onBilling: () -> Unit) {
    val c = LocalConsole.current
    val ai = ui.ai
    var prompt by rememberSaveable { mutableStateOf("") }
    var instruction by rememberSaveable { mutableStateOf("") }
    var hint by remember { mutableStateOf<Int?>(null) }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Legend(stringResource(R.string.ai_heading))
        Text(stringResource(R.string.ai_help), style = Type.small, color = c.muted)
        ui.billing?.let { BillingNote(it, onBilling) }

        OutlinedTextField(
            prompt, { prompt = it },
            label = { Text(stringResource(R.string.ai_prompt_label)) },
            placeholder = { Text(stringResource(R.string.ai_prompt_placeholder), style = Type.small) },
            textStyle = Type.bodyDense.copy(color = c.text),
            minLines = 2,
            enabled = !ai.running && ui.canEdit,
            modifier = Modifier.fillMaxWidth(),
        )
        SecondaryButton(stringResource(R.string.ai_generate), {
            if (prompt.isBlank()) hint = R.string.ai_enter_prompt else { hint = null; vm.generate(prompt) }
        }, Modifier.fillMaxWidth(), enabled = !ai.running && ui.canEdit && ui.accountId != null)

        if (hasText || ai.completed) {
            OutlinedTextField(
                instruction, { instruction = it },
                label = { Text(stringResource(R.string.ai_refine_label)) },
                placeholder = { Text(stringResource(R.string.ai_refine_placeholder), style = Type.small) },
                textStyle = Type.bodyDense.copy(color = c.text),
                enabled = !ai.running && ui.canEdit,
                modifier = Modifier.fillMaxWidth(),
            )
            SecondaryButton(stringResource(R.string.ai_refine), {
                hint = when {
                    instruction.isBlank() -> R.string.ai_enter_instructions
                    !hasText -> R.string.ai_nothing_to_refine
                    else -> null
                }
                if (hint == null) vm.refine(instruction)
            }, Modifier.fillMaxWidth(), enabled = !ai.running && ui.canEdit && ui.accountId != null)
        }
        hint?.let { NoteBlock(stringResource(it)) }

        if (ai.running || ai.preview.isNotEmpty() && !ai.completed) {
            Column(
                Modifier.fillMaxWidth().background(c.panel).border(1.dp, c.rule).padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (ai.running) CircularProgressIndicator(Modifier.size(16.dp), color = Palette.amber, strokeWidth = 2.dp)
                    Text(aiPhaseLabel(ai.phase), style = Type.label, color = c.legend, modifier = Modifier.weight(1f))
                    if (ai.running) SlugButton(stringResource(R.string.action_cancel), vm::cancelAi)
                }
                if (ai.preview.isEmpty()) Text(stringResource(R.string.ai_content_below), style = Type.small, color = c.muted)
                else Text(ai.preview, style = Type.mono, color = c.text)
            }
        }
        if (ai.completed && ai.replaced != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.ai_replaced), style = Type.small, color = c.legend, modifier = Modifier.weight(1f))
                SlugButton(stringResource(R.string.ai_undo), vm::undoAi)
            }
        } else if (ai.completed) {
            Text(stringResource(if (ai.refining) R.string.ai_refinement_complete else R.string.ai_generation_complete), style = Type.small, color = c.legend)
        }
        ai.error?.let { error ->
            AlarmBlock(error.ifBlank { stringResource(R.string.ai_connection_lost) }) {
                if (ai.paywall) SlugButton(stringResource(R.string.billing_note_link), onBilling, tone = SlugTone.Short)
            }
        }
    }
}

@Composable
private fun aiPhaseLabel(phase: String?): String = when (phase) {
    "generating" -> stringResource(R.string.ai_generating)
    "humanizing" -> stringResource(R.string.ai_humanizing)
    "refining" -> stringResource(R.string.ai_refining)
    else -> stringResource(R.string.ai_connecting)
}

/** Where the user stands with paid AI writing (web: posts/_ai_billing_note). Silent for paying users. */
@Composable
private fun BillingNote(billing: Billing, onBilling: () -> Unit) {
    if (!billing.enabled) return
    val date = Times.date(Times.parse(billing.until))
    val text = when (billing.state) {
        "none" -> stringResource(R.string.billing_note_none)
        "trial" -> stringResource(R.string.billing_note_trial, date)
        "expired" -> stringResource(R.string.billing_note_expired, date)
        else -> return
    }
    Row(
        Modifier.fillMaxWidth().border(1.dp, LocalConsole.current.rule).padding(start = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = Type.small, color = LocalConsole.current.legend, modifier = Modifier.weight(1f).padding(vertical = 8.dp))
        SlugButton(stringResource(R.string.billing_note_link), onBilling, tone = SlugTone.Wait)
    }
}

private const val MAX_PICK = 10
