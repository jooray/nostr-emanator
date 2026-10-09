package today.cypherpunk.emanator.ui

import android.app.Activity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Mail
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.activity.compose.LocalActivity
import androidx.compose.ui.res.stringResource
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

private val Tabs = listOf(
    Tab(Routes.DASHBOARD, R.string.nav_dashboard, Icons.Filled.Speed),
    Tab(Routes.POSTS, R.string.nav_posts, Icons.AutoMirrored.Filled.List),
    Tab(Routes.CALENDAR, R.string.nav_calendar, Icons.Filled.CalendarMonth),
    Tab(Routes.MESSAGES, R.string.nav_messages, Icons.Filled.Mail),
    Tab(Routes.MORE, R.string.nav_more, Icons.Filled.Menu),
)

@Composable
private fun MainNav(nav: NavHostController, container: AppContainer) {
    val entry by nav.currentBackStackEntryAsState()
    val current = entry?.destination?.route
    val me by container.me.collectAsState()
    val c = LocalConsole.current

    Scaffold(
        containerColor = c.chassis,
        bottomBar = {
            if (Tabs.any { it.route == current }) {
                NavigationBar(containerColor = c.panel, tonalElevation = androidx.compose.ui.unit.Dp(0f)) {
                    Tabs.forEach { tab ->
                        NavigationBarItem(
                            selected = current == tab.route,
                            onClick = {
                                nav.navigate(if (tab.route == Routes.POSTS) Routes.posts() else tab.route) {
                                    popUpTo(nav.graph.findStartDestination().id) { saveState = true }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = {
                                val summary = me?.summary
                                BadgedBox(badge = {
                                    when {
                                        tab.route == Routes.MESSAGES && (summary?.unreadMessages ?: 0) > 0 ->
                                            Badge(containerColor = Palette.amber, contentColor = Palette.contactBlack) { Text("${summary!!.unreadMessages}") }
                                        tab.route == Routes.MESSAGES && summary?.hasRequests == true -> Badge(containerColor = c.legend)
                                        tab.route == Routes.DASHBOARD && (summary?.failed ?: 0) + (summary?.short ?: 0) > 0 -> Badge(containerColor = Palette.red)
                                        tab.route == Routes.DASHBOARD && (summary?.waiting ?: 0) > 0 -> Badge(containerColor = Palette.amber)
                                    }
                                }) { Icon(tab.icon, contentDescription = null) }
                            },
                            label = { Text(stringResource(tab.label).uppercase(), style = Type.slug, maxLines = 1) },
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
        Box(Modifier.padding(bottom = padding.calculateBottomPadding())) {
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
