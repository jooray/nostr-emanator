package today.cypherpunk.emanator.ui

import android.app.Activity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Mail
import androidx.compose.material.icons.filled.CurrencyBitcoin
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.activity.compose.LocalActivity
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.BuildConfig
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.ui.components.NostrChooser
import today.cypherpunk.emanator.ui.screens.LoginScreen
import today.cypherpunk.emanator.ui.screens.UpdateRequiredScreen
import today.cypherpunk.emanator.ui.screens.accounts.AccountEditScreen
import today.cypherpunk.emanator.ui.screens.accounts.AccountScreen
import today.cypherpunk.emanator.ui.screens.accounts.AccountsScreen
import today.cypherpunk.emanator.ui.screens.accounts.PairScreen
import today.cypherpunk.emanator.ui.screens.accounts.ProfileEditScreen
import today.cypherpunk.emanator.ui.screens.compose.ComposeScreen
import today.cypherpunk.emanator.ui.screens.compose.ScheduleScreen
import today.cypherpunk.emanator.ui.screens.messages.ConversationScreen
import today.cypherpunk.emanator.ui.screens.messages.InteractionsScreen
import today.cypherpunk.emanator.ui.screens.messages.MessagesScreen
import today.cypherpunk.emanator.ui.screens.posts.CalendarScreen
import today.cypherpunk.emanator.ui.screens.posts.DashboardScreen
import today.cypherpunk.emanator.ui.screens.posts.PostScreen
import today.cypherpunk.emanator.ui.screens.posts.PostsScreen
import today.cypherpunk.emanator.ui.screens.settings.BillingScreen
import today.cypherpunk.emanator.ui.screens.settings.DevicesScreen
import today.cypherpunk.emanator.ui.screens.settings.McpTokensScreen
import today.cypherpunk.emanator.ui.screens.settings.MoreScreen
import today.cypherpunk.emanator.ui.screens.settings.SettingsScreen
import today.cypherpunk.emanator.ui.theme.EmanatorTheme
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.AppLocale
import java.time.ZoneId

@Composable
fun EmanatorRoot(container: AppContainer) {
    val token by container.session.token.collectAsState()
    val upgrade by container.upgrade.collectAsState()
    val me by container.me.collectAsState()
    val themePref = me?.user?.settings?.theme ?: container.prefs.theme

    CompositionLocalProvider(LocalContainer provides container) {
        EmanatorTheme(themePref) {
            when {
                upgrade != null -> UpdateRequiredScreen(upgrade!!)
                token == null -> LoginScreen()
                else -> SignedIn(container)
            }
        }
    }
}

/**
 * Once signed in: keep the user, settings and badges fresh, keep the server's
 * idea of the user's zone and language in step with the phone, and host the
 * navigation.
 */
@Composable
private fun SignedIn(container: AppContainer) {
    val activity = LocalActivity.current
    val nav = rememberNavController()
    val scope = rememberCoroutineScope()

    suspend fun refreshMe() {
        try {
            val me = container.api.me()
            container.setMe(me)
            container.prefs.theme = me.user.settings.theme
            syncZoneAndLanguage(container, me.user.settings.timezone, me.user.settings.locale, activity)
        } catch (_: ApiException) {
        }
    }

    LaunchedEffect(Unit) {
        refreshMe()
        runCatching { container.api.meta() }.getOrNull()?.let { meta ->
            if (BuildConfig.VERSION_CODE < meta.android.minVersionCode) container.requireUpgrade(meta.android)
        }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        // Badges move while the app is in the background.
        scope.launch { refreshMe() }
    }

    val deepLink by container.deepLink.collectAsState()
    LaunchedEffect(deepLink) {
        if (deepLink == "billing") nav.navigate(Routes.BILLING) { launchSingleTop = true }
        container.deepLink.value = null
    }
    val shared by container.shared.collectAsState()
    LaunchedEffect(shared) {
        if (shared != null) nav.navigate(Routes.compose(shared = true)) { launchSingleTop = true }
    }

    MainNav(nav, container)
    NostrChooser()
}

/**
 * The web records the browser's zone and the chosen language on the user; the
 * app does the same with the phone's, so scheduled times and server-written
 * text (signing steps, errors) agree everywhere.
 */
private suspend fun syncZoneAndLanguage(container: AppContainer, serverZone: String, serverLocale: String?, activity: Activity?) {
    val changes = mutableMapOf<String, Any?>()
    val phoneZone = ZoneId.systemDefault().id
    if (phoneZone != serverZone) changes["timezone"] = phoneZone

    val appChoice = container.prefs.locale
    val current = AppLocale.current(container.context)
    when {
        // A language picked on the web (or another device) wins over the phone default.
        serverLocale != null && appChoice == null && serverLocale != current -> {
            AppLocale.apply(container.context, serverLocale)
            activity?.recreate()
        }
        serverLocale == null -> changes["locale"] = current
        appChoice != null && appChoice != serverLocale -> changes["locale"] = appChoice
    }
    if (changes.isNotEmpty()) runCatching { container.setMe(container.api.updateMe(changes)) }
}

private data class Tab(val route: String, val label: Int, val icon: ImageVector)

/**
 * The bottom bar. Interactions earns a place here over Calendar: a reply is a
 * daily errand, the calendar is a plan looked at now and then. Five is the
 * bar's maximum, so Calendar goes behind More (and keeps its own rail entry
 * where the rail lists everything).
 */
private val Tabs = listOf(
    Tab(Routes.DASHBOARD, R.string.nav_dashboard, Icons.Filled.Speed),
    Tab(Routes.POSTS, R.string.nav_posts, Icons.AutoMirrored.Filled.List),
    Tab(Routes.INTERACTIONS, R.string.nav_interactions, Icons.Filled.Forum),
    Tab(Routes.MESSAGES, R.string.nav_messages, Icons.Filled.Mail),
    Tab(Routes.MORE, R.string.nav_more, Icons.Filled.Menu),
)

/** Destinations More holds; the rail lists them directly when the window is tall enough. */
private fun moreTabs(billing: Boolean) = listOfNotNull(
    Tab(Routes.COMPOSE, R.string.nav_new_post, Icons.Filled.Edit),
    Tab(Routes.ACCOUNTS, R.string.nav_accounts, Icons.Filled.People),
    Tab(Routes.CALENDAR, R.string.nav_calendar, Icons.Filled.CalendarMonth),
    Tab(Routes.SETTINGS, R.string.nav_settings, Icons.Filled.Settings),
    if (billing) Tab(Routes.BILLING, R.string.nav_billing, Icons.Filled.CurrencyBitcoin) else null,
)

/**
 * The rail lists every destination, so it keeps the bar's views in order and
 * then what the bar folds into More.
 */
private fun railTabs(billing: Boolean) = Tabs.dropLast(1) + moreTabs(billing)

/** Top-level destinations: the bar stays put on them, with More lit for Calendar. */
private val BarRoutes = Tabs.map { it.route }.toSet() + Routes.CALENDAR

/** A rail item with its label is about 56 dp tall, plus the rail's gaps. */
private val RailItemHeight = 64.dp

@Composable
private fun MainNav(nav: NavHostController, container: AppContainer) {
    val entry by nav.currentBackStackEntryAsState()
    val current = entry?.destination?.route
    val me by container.me.collectAsState()
    val c = LocalConsole.current
    val density = LocalDensity.current
    val window = LocalWindowInfo.current.containerSize
    val wide = with(density) { window.width.toDp() } >= 600.dp
    // A phone keeps the bottom bar with More (five is the bar's maximum). A
    // tablet gets a side rail listing every destination when they fit; a
    // landscape phone's rail does not have the height, so it keeps More.
    val billing = me?.billingEnabled == true
    val railItems = remember(billing) { railTabs(billing) }
    val fullRail = wide && with(density) { window.height.toDp() } >= RailItemHeight * railItems.size + 96.dp
    val selected = if (fullRail) Routes.railItemOf(current) else Routes.tabOf(current)
    val badge: @Composable (Tab) -> Unit = { tab -> TabBadge(tab, me?.summary) }
    val go: (Tab) -> Unit = { tab -> nav.switchTo(tab.route) }

    Scaffold(
        containerColor = c.chassis,
        bottomBar = {
            if (!wide && current in BarRoutes) {
                NavigationBar(containerColor = c.panel, tonalElevation = androidx.compose.ui.unit.Dp(0f)) {
                    Tabs.forEach { tab ->
                        NavigationBarItem(
                            selected = tab.route == selected,
                            onClick = { go(tab) },
                            icon = { BadgedBox(badge = { badge(tab) }) { Icon(tab.icon, contentDescription = null) } },
                            label = {
                                // "Interactions" (and "Interacciones") is wider than the
                                // bar's slot for it: shrink rather than cut a word short.
                                Text(
                                    stringResource(tab.label).uppercase(), style = Type.slug, maxLines = 1,
                                    autoSize = TextAutoSize.StepBased(minFontSize = 8.sp, maxFontSize = 11.5.sp),
                                )
                            },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = c.text, selectedTextColor = c.text,
                                unselectedIconColor = c.muted, unselectedTextColor = c.muted,
                                indicatorColor = c.activeFill,
                            ),
                        )
                    }
                }
            }
        },
    ) { padding ->
        Row {
            if (wide) {
                // The rail's own insets pad inside its panel, so the panel runs edge to edge.
                NavigationRail(
                    Modifier.fillMaxHeight(),
                    containerColor = c.panel,
                    windowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Start + WindowInsetsSides.Vertical),
                ) {
                    Spacer(Modifier.height(8.dp))
                    (if (fullRail) railItems else Tabs).forEach { tab ->
                        NavigationRailItem(
                            selected = selected == tab.route,
                            onClick = { go(tab) },
                            icon = { BadgedBox(badge = { badge(tab) }) { Icon(tab.icon, contentDescription = null) } },
                            label = {
                                // A long label (sk "Predplatné AI písania") wraps rather than widening the rail.
                                Text(
                                    stringResource(tab.label).uppercase(), style = Type.slug, maxLines = 2,
                                    textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 100.dp),
                                )
                            },
                            colors = NavigationRailItemDefaults.colors(
                                selectedIconColor = c.text, selectedTextColor = c.text,
                                unselectedIconColor = c.muted, unselectedTextColor = c.muted,
                                indicatorColor = c.activeFill,
                            ),
                        )
                    }
                }
                VerticalDivider(color = c.rule)
            }
            Box(
                Modifier.weight(1f).fillMaxHeight().padding(bottom = padding.calculateBottomPadding())
                    .then(if (wide) Modifier.consumeWindowInsets(WindowInsets.safeDrawing.only(WindowInsetsSides.Start)) else Modifier),
            ) {
                NavHost(nav, startDestination = Routes.DASHBOARD) {
                    composable(Routes.DASHBOARD) { DashboardScreen(nav) }
                    composable(
                        Routes.POSTS,
                        arguments = listOf(
                            navArgument("status") { type = NavType.StringType; defaultValue = "" },
                            navArgument("account") { type = NavType.LongType; defaultValue = 0L },
                        ),
                    ) { e ->
                        PostsScreen(nav, e.arguments?.getString("status")?.ifBlank { null }, e.arguments?.getLong("account")?.takeIf { it > 0 })
                    }
                    composable(Routes.CALENDAR) { CalendarScreen(nav) }
                    composable(Routes.MESSAGES) { MessagesScreen(nav) }
                    composable(Routes.MORE) { MoreScreen(nav) }

                    composable(Routes.POST, arguments = listOf(navArgument("id") { type = NavType.LongType })) { e ->
                        PostScreen(nav, e.arguments!!.getLong("id"))
                    }
                    composable(
                        Routes.COMPOSE,
                        arguments = listOf(
                            navArgument("account") { type = NavType.LongType; defaultValue = 0L },
                            navArgument("post") { type = NavType.LongType; defaultValue = 0L },
                            navArgument("shared") { type = NavType.BoolType; defaultValue = false },
                        ),
                    ) { e ->
                        ComposeScreen(
                            nav,
                            accountId = e.arguments?.getLong("account")?.takeIf { it > 0 },
                            postId = e.arguments?.getLong("post")?.takeIf { it > 0 },
                            fromShare = e.arguments?.getBoolean("shared") ?: false,
                        )
                    }
                    composable(
                        Routes.SCHEDULE,
                        arguments = listOf(
                            navArgument("id") { type = NavType.LongType },
                            navArgument("reposts") { type = NavType.StringType; defaultValue = "" },
                        ),
                    ) { e ->
                        val reposts = e.arguments?.getString("reposts").orEmpty().split(",").mapNotNull { it.toLongOrNull() }
                        ScheduleScreen(nav, e.arguments!!.getLong("id"), reposts)
                    }
                    composable(Routes.CONVERSATION, arguments = listOf(navArgument("id") { type = NavType.LongType })) { e ->
                        ConversationScreen(nav, e.arguments!!.getLong("id"))
                    }
                    composable(Routes.INTERACTIONS) { InteractionsScreen(nav) }
                    composable(Routes.ACCOUNTS) { AccountsScreen(nav) }
                    composable(Routes.ACCOUNT, arguments = listOf(navArgument("id") { type = NavType.LongType })) { e ->
                        AccountScreen(nav, e.arguments!!.getLong("id"))
                    }
                    composable(Routes.ACCOUNT_EDIT, arguments = listOf(navArgument("id") { type = NavType.LongType })) { e ->
                        AccountEditScreen(nav, e.arguments!!.getLong("id"))
                    }
                    composable(Routes.ACCOUNT_PROFILE, arguments = listOf(navArgument("id") { type = NavType.LongType })) { e ->
                        ProfileEditScreen(nav, e.arguments!!.getLong("id"))
                    }
                    composable(
                        Routes.PAIR,
                        arguments = listOf(
                            navArgument("account") { type = NavType.LongType; defaultValue = 0L },
                            navArgument("reason") { type = NavType.StringType; defaultValue = "" },
                        ),
                    ) { e ->
                        PairScreen(nav, e.arguments?.getLong("account")?.takeIf { it > 0 }, e.arguments?.getString("reason")?.ifBlank { null })
                    }
                    composable(Routes.SETTINGS) { SettingsScreen(nav) }
                    composable(Routes.BILLING) { BillingScreen(nav) }
                    composable(Routes.DEVICES) { DevicesScreen(nav) }
                    composable(Routes.MCP_TOKENS) { McpTokensScreen(nav) }
                }
            }
        }
    }
}

private fun NavHostController.switchTo(route: String) {
    // New post always opens an empty composer; the other tabs come back as they were left.
    val fresh = route == Routes.COMPOSE
    navigate(
        when (route) {
            Routes.POSTS -> Routes.posts()
            Routes.COMPOSE -> Routes.compose()
            else -> route
        },
    ) {
        popUpTo(graph.findStartDestination().id) { saveState = !fresh }
        launchSingleTop = true
        restoreState = !fresh
    }
}

/** Dashboard and Messages carry the same counts as the web's nav. */
@Composable
private fun TabBadge(tab: Tab, summary: today.cypherpunk.emanator.data.Summary?) {
    val c = LocalConsole.current
    when {
        tab.route == Routes.MESSAGES && (summary?.unreadMessages ?: 0) > 0 ->
            Badge(containerColor = Palette.amber, contentColor = Palette.contactBlack) { Text("${summary!!.unreadMessages}") }
        tab.route == Routes.MESSAGES && summary?.hasRequests == true -> Badge(containerColor = c.legend)
        tab.route == Routes.DASHBOARD && (summary?.failed ?: 0) + (summary?.short ?: 0) > 0 -> Badge(containerColor = Palette.red)
        tab.route == Routes.DASHBOARD && (summary?.waiting ?: 0) > 0 -> Badge(containerColor = Palette.amber)
    }
}
