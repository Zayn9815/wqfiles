package com.wqglass.transfer

import android.content.Context
import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class WQAndroidThemeSpec(
    val id: String,
    val title: String,
    val subtitle: String,
    val canvasTop: Color,
    val canvasMid: Color,
    val cardBg: Color,
    val cardElevated: Color,
    val cardBorder: Color,
    val inputBg: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val accent: Color,
    val secondaryAccent: Color,
    val activePill: Color
)

data class WQUIStyleSpec(
    val id: String,
    val title: String,
    val subtitle: String,
    val cornerRadiusDp: Int,
    val borderWidthDp: Float,
    val cardPaddingDp: Int
)

object WQThemeEngine {
    const val THEME_IPHONE_DUO = "iphone_duo"
    const val THEME_GLACIER_GLASS = "glacier_glass"
    const val THEME_CRIMSON_GLASS = "crimson_glass"
    const val THEME_ANODIZED_OBSIDIAN = "anodized_obsidian"
    const val THEME_CLASSIC_NATIVE = "classic_native"

    const val STYLE_DUO_HUD = "duo_hud"
    const val STYLE_LIQUID_GLASS = "liquid_glass"
    const val STYLE_COMPACT_PRO = "compact_pro"

    val allThemes: List<WQAndroidThemeSpec> = listOf(
        WQAndroidThemeSpec(
            id = THEME_IPHONE_DUO,
            title = "iPhone Duo (Default)",
            subtitle = "Deep slate glass with electric iOS blue & cyan accents",
            canvasTop = Color(0xFF090A0D),
            canvasMid = Color(0xFF12151B),
            cardBg = Color(0xFF161920),
            cardElevated = Color(0xFF1C2029),
            cardBorder = Color(0xFF2B3242),
            inputBg = Color(0xFF0E1015),
            textPrimary = Color(0xFFFFFFFF),
            textSecondary = Color(0xFF9BA3B0),
            accent = Color(0xFF0A84FF),
            secondaryAccent = Color(0xFF5AC8FA),
            activePill = Color(0xFF0A84FF)
        ),
        WQAndroidThemeSpec(
            id = THEME_GLACIER_GLASS,
            title = "Glacier Liquid Glass",
            subtitle = "Arctic translucent blue with neon cyan & aurora mint",
            canvasTop = Color(0xFF091524),
            canvasMid = Color(0xFF122B43),
            cardBg = Color(0xFF102A45),
            cardElevated = Color(0xFF163759),
            cardBorder = Color(0xFF28597A),
            inputBg = Color(0xFF071626),
            textPrimary = Color(0xFFFFFFFF),
            textSecondary = Color(0xFFB0E2FF),
            accent = Color(0xFF00F5FF),
            secondaryAccent = Color(0xFF4FFFB0),
            activePill = Color(0xFF0E5A74)
        ),
        WQAndroidThemeSpec(
            id = THEME_CRIMSON_GLASS,
            title = "Crimson Velvet Glass",
            subtitle = "Rich ruby glass with vibrant rose & coral highlights",
            canvasTop = Color(0xFF1A050A),
            canvasMid = Color(0xFF380B16),
            cardBg = Color(0xFF2C0811),
            cardElevated = Color(0xFF3A0C18),
            cardBorder = Color(0xFF6B1D31),
            inputBg = Color(0xFF140307),
            textPrimary = Color(0xFFFFFFFF),
            textSecondary = Color(0xFFF4B8C4),
            accent = Color(0xFFFF2D55),
            secondaryAccent = Color(0xFFFF6482),
            activePill = Color(0xFFA81838)
        ),
        WQAndroidThemeSpec(
            id = THEME_ANODIZED_OBSIDIAN,
            title = "Anodized Obsidian",
            subtitle = "Tactical carbon graphite with emerald telemetry accents",
            canvasTop = Color(0xFF090B0E),
            canvasMid = Color(0xFF12161D),
            cardBg = Color(0xFF141820),
            cardElevated = Color(0xFF1A202B),
            cardBorder = Color(0xFF293242),
            inputBg = Color(0xFF0B0E12),
            textPrimary = Color(0xFFFFFFFF),
            textSecondary = Color(0xFF8E96A4),
            accent = Color(0xFF32D74B),
            secondaryAccent = Color(0xFF63E686),
            activePill = Color(0xFF1E7D32)
        ),
        WQAndroidThemeSpec(
            id = THEME_CLASSIC_NATIVE,
            title = "Classic Native OLED",
            subtitle = "True OLED black canvas with high-contrast system cards",
            canvasTop = Color(0xFF000000),
            canvasMid = Color(0xFF0E0E10),
            cardBg = Color(0xFF1C1C1E),
            cardElevated = Color(0xFF262629),
            cardBorder = Color(0xFF38383A),
            inputBg = Color(0xFF101012),
            textPrimary = Color(0xFFFFFFFF),
            textSecondary = Color(0xFF98989F),
            accent = Color(0xFF0A84FF),
            secondaryAccent = Color(0xFF64D2FF),
            activePill = Color(0xFF0A84FF)
        )
    )

    val allStyles: List<WQUIStyleSpec> = listOf(
        WQUIStyleSpec(
            id = STYLE_DUO_HUD,
            title = "Duo HUD (Default)",
            subtitle = "Balanced rounded glass cards with crisp 1dp borders",
            cornerRadiusDp = 16,
            borderWidthDp = 1f,
            cardPaddingDp = 12
        ),
        WQUIStyleSpec(
            id = STYLE_LIQUID_GLASS,
            title = "Full Liquid Glass",
            subtitle = "Deeply sculpted 22dp glass capsules with luminous rims",
            cornerRadiusDp = 22,
            borderWidthDp = 1.4f,
            cardPaddingDp = 14
        ),
        WQUIStyleSpec(
            id = STYLE_COMPACT_PRO,
            title = "Compact Pro",
            subtitle = "High-density studio rows for maximum visible items",
            cornerRadiusDp = 11,
            borderWidthDp = 0.8f,
            cardPaddingDp = 9
        )
    )

    private val _currentTheme = MutableStateFlow(allThemes[0])
    val currentTheme: StateFlow<WQAndroidThemeSpec> = _currentTheme.asStateFlow()

    private val _currentStyle = MutableStateFlow(allStyles[0])
    val currentStyle: StateFlow<WQUIStyleSpec> = _currentStyle.asStateFlow()

    private val _allowDeleting = MutableStateFlow(true)
    val allowDeleting: StateFlow<Boolean> = _allowDeleting.asStateFlow()

    private val _showHiddenFiles = MutableStateFlow(false)
    val showHiddenFiles: StateFlow<Boolean> = _showHiddenFiles.asStateFlow()

    private val _showItemCounts = MutableStateFlow(true)
    val showItemCounts: StateFlow<Boolean> = _showItemCounts.asStateFlow()

    private val _safeReadOnlyMode = MutableStateFlow(false)
    val safeReadOnlyMode: StateFlow<Boolean> = _safeReadOnlyMode.asStateFlow()

    fun init(context: Context) {
        val prefs = context.getSharedPreferences("wqglass_theme_prefs", Context.MODE_PRIVATE)
        val themeId = prefs.getString("selected_theme_id", THEME_IPHONE_DUO) ?: THEME_IPHONE_DUO
        val styleId = prefs.getString("selected_style_id", STYLE_DUO_HUD) ?: STYLE_DUO_HUD
        _currentTheme.value = allThemes.firstOrNull { it.id == themeId } ?: allThemes[0]
        _currentStyle.value = allStyles.firstOrNull { it.id == styleId } ?: allStyles[0]
        _allowDeleting.value = prefs.getBoolean("allow_deleting", true)
        _showHiddenFiles.value = prefs.getBoolean("show_hidden_files", false)
        _showItemCounts.value = prefs.getBoolean("show_item_counts", true)
        _safeReadOnlyMode.value = prefs.getBoolean("safe_read_only", false)
    }

    fun selectTheme(context: Context, themeId: String) {
        val found = allThemes.firstOrNull { it.id == themeId } ?: allThemes[0]
        _currentTheme.value = found
        context.getSharedPreferences("wqglass_theme_prefs", Context.MODE_PRIVATE)
            .edit().putString("selected_theme_id", found.id).apply()
    }

    fun selectStyle(context: Context, styleId: String) {
        val found = allStyles.firstOrNull { it.id == styleId } ?: allStyles[0]
        _currentStyle.value = found
        context.getSharedPreferences("wqglass_theme_prefs", Context.MODE_PRIVATE)
            .edit().putString("selected_style_id", found.id).apply()
    }

    fun setAllowDeleting(context: Context, enabled: Boolean) {
        _allowDeleting.value = enabled
        context.getSharedPreferences("wqglass_theme_prefs", Context.MODE_PRIVATE)
            .edit().putBoolean("allow_deleting", enabled).apply()
    }

    fun setShowHiddenFiles(context: Context, enabled: Boolean) {
        _showHiddenFiles.value = enabled
        context.getSharedPreferences("wqglass_theme_prefs", Context.MODE_PRIVATE)
            .edit().putBoolean("show_hidden_files", enabled).apply()
    }

    fun setShowItemCounts(context: Context, enabled: Boolean) {
        _showItemCounts.value = enabled
        context.getSharedPreferences("wqglass_theme_prefs", Context.MODE_PRIVATE)
            .edit().putBoolean("show_item_counts", enabled).apply()
    }

    fun setSafeReadOnlyMode(context: Context, enabled: Boolean) {
        _safeReadOnlyMode.value = enabled
        context.getSharedPreferences("wqglass_theme_prefs", Context.MODE_PRIVATE)
            .edit().putBoolean("safe_read_only", enabled).apply()
    }
}
