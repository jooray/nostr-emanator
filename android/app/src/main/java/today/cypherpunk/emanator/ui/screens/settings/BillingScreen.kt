package today.cypherpunk.emanator.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavHostController
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Billing
import today.cypherpunk.emanator.data.Plan
import today.cypherpunk.emanator.ui.LocalContainer
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.NoteBlock
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.screens.accounts.Field
import today.cypherpunk.emanator.ui.screens.accounts.LoadVm
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links
import today.cypherpunk.emanator.util.Times
import java.text.NumberFormat
import java.util.Locale

private const val PRODUCT = "emanator-ai"

private fun sats(value: Long): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(value)
private fun date(iso: String?): String = Times.date(Times.parse(iso))

/** The one-line status the Settings page shows (web: billing/_settings_section). */
@Composable
internal fun billingNote(billing: Billing): String = when (billing.state) {
    "active" -> stringResource(R.string.bill_active, date(billing.until))
    "trial" -> stringResource(R.string.bill_trial, date(billing.until))
    "expired" -> stringResource(R.string.bill_note_expired, date(billing.until))
    "none" -> stringResource(R.string.bill_note_none)
    else -> stringResource(R.string.bill_unknown)
}

/**
 * Paid AI assist (web: billing/show). Paying opens the BTCPay checkout in the
 * phone's browser; BTCPay returns the payer to /billing/return, which hands
 * them back here (emanator://billing). Coming back re-reads the status, and the
 * server reports a settled charge exactly once.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun BillingScreen(nav: NavHostController) {
    val container = LocalContainer.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val me by container.me.collectAsState()
    val vm = appViewModel("billing") { c -> LoadVm(c.cache, "billing", Billing.serializer()) { c.api.billing() } }
    val state by vm.state.collectAsState()
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.load() }

    var awaitingPayment by rememberSaveable { mutableStateOf(false) }
    var settledUntil by rememberSaveable { mutableStateOf<String?>(null) }
    var chargeError by remember { mutableStateOf<String?>(null) }
    var paying by remember { mutableStateOf(false) }

    // `settled` is reported once by the server; the copy on disk would replay it.
    LaunchedEffect(state.data?.settled, state.fromCache) {
        if (state.fromCache) return@LaunchedEffect
        state.data?.settled?.let {
            settledUntil = state.data?.until
            awaitingPayment = false
        }
    }
    // Back from the checkout: BTCPay may settle a few seconds later, so keep
    // asking (while on screen) until it does, like the web billing page.
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(awaitingPayment, settledUntil) {
        if (!awaitingPayment || settledUntil != null) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                kotlinx.coroutines.delay(4_000)
                vm.load()
            }
        }
    }

    fun pay(plan: String, amount: Long?) {
        paying = true
        chargeError = null
        scope.launch {
            try {
                val checkout = container.api.createCharge(plan, amount)
                awaitingPayment = true
                Links.openUrl(context, checkout.checkoutUrl)
            } catch (e: ApiException) {
                chargeError = e.message
            } finally {
                paying = false
            }
        }
    }

    ConsoleScaffold(stringResource(R.string.bill_title), onBack = { nav.popBackStack() }) { padding ->
        val error = state.error
        if (state.data == null && error?.status == 404) {
            Box(Modifier.padding(padding).padding(Gutter)) { NoteBlock(stringResource(R.string.bill_disabled)) }
            return@ConsoleScaffold
        }
        LoadableContent(state, onRefresh = vm::load, modifier = Modifier.padding(padding).imePadding()) { billing ->
            val c = LocalConsole.current
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Gutter),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(stringResource(R.string.bill_intro), style = Type.small, color = c.muted)

                settledUntil?.let { NoteBlock(stringResource(R.string.bill_settled, date(it))) }
                if (awaitingPayment && settledUntil == null) WaitBlock(stringResource(R.string.bill_waiting))

                Legend(stringResource(R.string.bill_status_title))
                Text(
                    when (billing.state) {
                        "active" -> stringResource(R.string.bill_active, date(billing.until))
                        "trial" -> stringResource(R.string.bill_trial, date(billing.until))
                        "expired" -> stringResource(R.string.bill_expired, date(billing.until))
                        "none" -> stringResource(R.string.bill_none)
                        else -> stringResource(R.string.bill_unknown)
                    },
                    style = Type.bodyDense, color = c.text,
                )
                billing.others.forEach { other ->
                    Text(stringResource(R.string.bill_other, productName(other.product), date(other.until)), style = Type.small, color = c.legend)
                }
                me?.user?.npub?.let { Text(stringResource(R.string.bill_npub, it), style = Type.mono, color = c.muted) }

                val plans = billing.plans
                if (plans.isNullOrEmpty()) {
                    AlarmBlock(stringResource(R.string.bill_unavailable))
                } else {
                    plans.forEachIndexed { index, plan ->
                        Rule()
                        PlanBlock(plan, primary = index == 0, enabled = !paying) { pay(plan.id, null) }
                    }
                    Rule()
                    CustomAmount(billing, plans, enabled = !paying) { plan, amount -> pay(plan, amount) }
                }
                chargeError?.let { AlarmBlock(it) }

                Rule()
                Text(stringResource(R.string.bill_self_host), style = Type.small, color = c.muted)
                SlugButton(stringResource(R.string.bill_self_host_link), { Links.openUrl(context, "https://github.com/jooray/nostr-emanator") })
            }
        }
    }
}

@Composable
private fun productName(product: String) = when (product) {
    "nalgorithm" -> stringResource(R.string.bill_product_nalgorithm)
    "lievik" -> stringResource(R.string.bill_product_lievik)
    "all-access" -> stringResource(R.string.bill_plan_all_name)
    PRODUCT -> stringResource(R.string.bill_plan_emanator_name)
    else -> product
}

@Composable
private fun PlanBlock(plan: Plan, primary: Boolean, enabled: Boolean, onPay: () -> Unit) {
    val c = LocalConsole.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(productName(plan.id).uppercase(), style = Type.title, color = c.text)
        Text(
            stringResource(R.string.bill_price, sats(plan.sats), pluralStringResource(R.plurals.bill_days, plan.days, plan.days)),
            style = Type.readout, color = c.text,
        )
        Text(
            stringResource(if (plan.id == PRODUCT) R.string.bill_plan_emanator_covers else R.string.bill_plan_all_covers),
            style = Type.small, color = c.muted,
        )
        val label = stringResource(R.string.bill_pay, sats(plan.sats))
        if (primary) PrimaryButton(label, onPay, Modifier.fillMaxWidth(), enabled = enabled)
        else SecondaryButton(label, onPay, Modifier.fillMaxWidth(), enabled = enabled)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CustomAmount(billing: Billing, plans: List<Plan>, enabled: Boolean, onPay: (String, Long) -> Unit) {
    val c = LocalConsole.current
    var plan by rememberSaveable { mutableStateOf(plans.first().id) }
    var amount by rememberSaveable { mutableStateOf("") }
    val value = amount.toLongOrNull()
    val inRange = value != null && value in billing.minSats..billing.maxSats

    // How many days the minimum buys, the way the web phrases it.
    val base = plans.firstOrNull { it.id == PRODUCT }
    val days = base?.let {
        val d = billing.minSats * it.days / it.sats.toDouble()
        String.format(Locale.getDefault(), "%.1f", d).removeSuffix(".0").removeSuffix(",0")
    } ?: "—"

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Legend(stringResource(R.string.bill_custom_title))
        Text(stringResource(R.string.bill_custom_help, sats(billing.minSats), days), style = Type.small, color = c.muted)
        Text(stringResource(R.string.bill_custom_plan).uppercase(), style = Type.slug, color = c.muted)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            plans.forEach { p -> Chip(productName(p.id), plan == p.id) { plan = p.id } }
        }
        Field(
            stringResource(R.string.bill_custom_sats), amount, { amount = it.filter(Char::isDigit) },
            keyboardType = KeyboardType.Number, isError = amount.isNotEmpty() && !inRange,
            help = if (amount.isNotEmpty() && !inRange) stringResource(R.string.bill_sats_range, sats(billing.minSats), sats(billing.maxSats)) else null,
        )
        SecondaryButton(stringResource(R.string.bill_custom_pay), { value?.let { onPay(plan, it) } }, Modifier.fillMaxWidth(), enabled = enabled && inRange)
    }
}
