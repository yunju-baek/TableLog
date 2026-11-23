package work.yunju.tablelog.ui

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

val Forest = Color(0xFF235A49)
val Paper = Color(0xFFF7F8F4)
val Ink = Color(0xFF202B26)
val Muted = Color(0xFF647269)
val Orange = Color(0xFFC34E35)

@Composable fun TableLogTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(primary = Forest, onPrimary = Color.White,
            primaryContainer = Color(0xFFE3EEE6), onPrimaryContainer = Forest,
            secondary = Muted, background = Paper, surface = Paper, onSurface = Ink,
            surfaceVariant = Color(0xFFEDF0EA), onSurfaceVariant = Muted, outline = Color(0xFFBBC7BD), error = Color(0xFFAF392B)),
        typography = Typography(
            headlineLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Bold, fontSize = 30.sp, lineHeight = 40.sp),
            headlineMedium = TextStyle(fontWeight = FontWeight.Bold, fontSize = 25.sp, lineHeight = 34.sp),
            titleLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 21.sp, lineHeight = 30.sp),
            bodyLarge = TextStyle(fontSize = 16.sp, lineHeight = 26.sp),
            bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 22.sp),
        ), content = content,
    )
}
