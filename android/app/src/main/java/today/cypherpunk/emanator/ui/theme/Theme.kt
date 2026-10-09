package today.cypherpunk.emanator.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import today.cypherpunk.emanator.R

// "Emanator Console" (DESIGN.md): a warm graphite chassis, hairline rules,
// engraved condensed legend, and exactly two chromatic values — amber means a
// human must act, red means something did not land. Nominal states stay dark.

object Palette {
    val chassis = Color(0xFF211F1C)
    val panel = Color(0xFF2E2B27)
    val panelHi = Color(0xFF353128)
    val seam = Color(0xFF171512)
    val well = Color(0xFF413C35)
    val ruleDark = Color(0xFF403B34)
    val bone = Color(0xFFCFC7BB)
    val legend = Color(0xFFC4BBAC)
    val warmStock = Color(0xFFEFEBE4)
    val paperWhite = Color(0xFFFAF7F2)
    val neutral100 = Color(0xFFE4DFD6)
    val neutral200 = Color(0xFFD3CCC1)
    val neutral300 = Color(0xFFBBB3A6)
    val neutral400 = Color(0xFFA49B8C)
    val neutral500 = Color(0xFF6E665A)
    val neutral600 = Color(0xFF554E44)
    val neutral700 = Color(0xFF383430)
    val inkDark = Color(0xFFEDE8E0)
    val contactBlack = Color(0xFF1A1714)
    val amber = Color(0xFFF0A017)
    val amberLift = Color(0xFFF5B950)
    val amberDeep = Color(0xFFD98A0C)
    val amberInk = Color(0xFFB8720A)
    val red = Color(0xFFD93B1E)
    val redLift = Color(0xFFE8614A)
    val redDeep = Color(0xFFC22F14)
    val redInk = Color(0xFFA02610)
}

/** The console's own roles, beyond what Material's scheme names. */
@Immutable
data class ConsoleColors(
    val dark: Boolean,
    val chassis: Color,
    val panel: Color,
    val panelHi: Color,
    val rule: Color,
    val well: Color,
    val text: Color,
    val legend: Color,
    val muted: Color,
    val lampLit: Color,
    val amber: Color,
    /** Amber as text on the background (darker in the light theme to stay legible). */
    val amberText: Color,
    val red: Color,
    val redText: Color,
    val waitFill: Color,
    val alarmFill: Color,
    val activeFill: Color,
)

private val DarkConsole = ConsoleColors(
    dark = true,
    chassis = Palette.chassis,
    panel = Palette.panel,
    panelHi = Palette.panelHi,
    rule = Palette.ruleDark,
    well = Palette.well,
    text = Palette.inkDark,
    legend = Palette.legend,
    muted = Palette.neutral400,
    lampLit = Palette.bone,
    amber = Palette.amber,
    amberText = Palette.amber,
    red = Palette.red,
    redText = Palette.redLift,
    waitFill = Color(0x17F0A017),
    alarmFill = Color(0x14D93B1E),
    activeFill = Color(0x14F0A017),
)

private val LightConsole = ConsoleColors(
    dark = false,
    chassis = Palette.warmStock,
    panel = Palette.paperWhite,
    panelHi = Palette.neutral100,
    rule = Palette.neutral200,
    well = Palette.neutral200,
    text = Palette.contactBlack,
    legend = Palette.neutral600,
    muted = Palette.neutral500,
    lampLit = Palette.neutral600,
    amber = Palette.amber,
    amberText = Palette.amberInk,
    red = Palette.red,
    redText = Palette.redInk,
    waitFill = Color(0x17F0A017),
    alarmFill = Color(0x14D93B1E),
    activeFill = Color(0x14F0A017),
)

val LocalConsole = staticCompositionLocalOf { DarkConsole }

val Barlow = FontFamily(
    Font(R.font.barlow_regular, FontWeight.Normal),
    Font(R.font.barlow_medium, FontWeight.Medium),
    Font(R.font.barlow_semibold, FontWeight.SemiBold),
    Font(R.font.barlow_bold, FontWeight.Bold),
)

val BarlowCondensed = FontFamily(
    Font(R.font.barlow_condensed_medium, FontWeight.Medium),
    Font(R.font.barlow_condensed_semibold, FontWeight.SemiBold),
    Font(R.font.barlow_condensed_bold, FontWeight.Bold),
)

val JetBrainsMono = FontFamily(
    Font(R.font.jetbrains_mono, FontWeight.Normal, variationSettings = FontVariation.Settings(FontVariation.weight(400))),
    Font(R.font.jetbrains_mono, FontWeight.Bold, variationSettings = FontVariation.Settings(FontVariation.weight(700))),
)

/** Engraved legend: condensed caps with wide tracking. Uppercase the text yourself. */
object Type {
    val display = TextStyle(fontFamily = BarlowCondensed, fontWeight = FontWeight.Bold, fontSize = 30.sp, lineHeight = 32.sp, letterSpacing = 0.06.em)
    val headline = TextStyle(fontFamily = BarlowCondensed, fontWeight = FontWeight.Bold, fontSize = 24.sp, lineHeight = 26.sp, letterSpacing = 0.06.em)
    val title = TextStyle(fontFamily = BarlowCondensed, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, lineHeight = 18.sp, letterSpacing = 0.1.em)
    val label = TextStyle(fontFamily = BarlowCondensed, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, lineHeight = 15.sp, letterSpacing = 0.16.em)
    val slug = TextStyle(fontFamily = BarlowCondensed, fontWeight = FontWeight.SemiBold, fontSize = 11.5.sp, lineHeight = 12.sp, letterSpacing = 0.18.em)
    val body = TextStyle(fontFamily = Barlow, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 25.sp)
    val bodyDense = TextStyle(fontFamily = Barlow, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 22.sp)
    val small = TextStyle(fontFamily = Barlow, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 18.sp)
    val hour = TextStyle(fontFamily = JetBrainsMono, fontWeight = FontWeight.Bold, fontSize = 22.sp, lineHeight = 22.sp, letterSpacing = (-0.02).em)
    val readout = TextStyle(fontFamily = JetBrainsMono, fontWeight = FontWeight.Bold, fontSize = 14.sp, lineHeight = 18.sp)
    val mono = TextStyle(fontFamily = JetBrainsMono, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 18.sp)
}

private val Square = RoundedCornerShape(0.dp)

@Composable
fun EmanatorTheme(themePref: String = "system", content: @Composable () -> Unit) {
    val dark = when (themePref) {
        "dark" -> true
        "light" -> false
        else -> isSystemInDarkTheme()
    }
    val console = if (dark) DarkConsole else LightConsole

    val scheme = if (dark) {
        darkColorScheme(
            primary = Palette.amber, onPrimary = Palette.contactBlack,
            secondary = Palette.bone, onSecondary = Palette.contactBlack,
            background = console.chassis, onBackground = console.text,
            surface = console.chassis, onSurface = console.text,
            surfaceVariant = console.panel, onSurfaceVariant = console.legend,
            surfaceContainer = console.panel, surfaceContainerHigh = console.panelHi,
            surfaceContainerHighest = console.panelHi, surfaceContainerLow = console.panel,
            surfaceContainerLowest = Palette.seam,
            outline = console.rule, outlineVariant = console.rule,
            error = Palette.red, onError = Palette.paperWhite,
        )
    } else {
        lightColorScheme(
            primary = Palette.amber, onPrimary = Palette.contactBlack,
            secondary = Palette.neutral600, onSecondary = Palette.paperWhite,
            background = console.chassis, onBackground = console.text,
            surface = console.chassis, onSurface = console.text,
            surfaceVariant = console.panel, onSurfaceVariant = console.legend,
            surfaceContainer = console.panel, surfaceContainerHigh = console.panelHi,
            surfaceContainerHighest = console.panelHi, surfaceContainerLow = console.panel,
            surfaceContainerLowest = Palette.paperWhite,
            outline = console.rule, outlineVariant = console.rule,
            error = Palette.red, onError = Palette.paperWhite,
        )
    }

    val typography = Typography(
        displaySmall = Type.display,
        headlineSmall = Type.headline,
        titleLarge = Type.headline,
        titleMedium = Type.title,
        titleSmall = Type.title,
        bodyLarge = Type.body,
        bodyMedium = Type.bodyDense,
        bodySmall = Type.small,
        labelLarge = Type.label,
        labelMedium = Type.label,
        labelSmall = Type.slug,
    )

    // System bar icons follow the app's theme, which can differ from the phone's.
    val view = androidx.compose.ui.platform.LocalView.current
    val activity = androidx.activity.compose.LocalActivity.current
    if (!view.isInEditMode && activity != null) {
        androidx.compose.runtime.SideEffect {
            androidx.core.view.WindowCompat.getInsetsController(activity.window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }

    CompositionLocalProvider(LocalConsole provides console) {
        MaterialTheme(
            colorScheme = scheme,
            typography = typography,
            shapes = Shapes(Square, Square, Square, Square, Square),
            content = content,
        )
    }
}
