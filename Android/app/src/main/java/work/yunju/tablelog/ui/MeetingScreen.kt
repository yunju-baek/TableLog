package work.yunju.tablelog.ui

import android.media.MediaPlayer
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay
import work.yunju.tablelog.audio.*
import work.yunju.tablelog.data.*
import work.yunju.tablelog.ai.SpeechMode
import java.io.File

@Composable fun MeetingScreen(
    meeting: Meeting, recording: RecordingState, audio: File?, onCommand: (String) -> Unit,
    onEdit: ((Meeting) -> Meeting) -> Unit, onDelete: () -> Unit,
    onAI: (Boolean) -> Unit, aiBusy: Boolean,
    speechMode: SpeechMode, onSpeechMode: (SpeechMode) -> Unit,
    hasLocalProposal: Boolean = false, onLocalProposal: () -> Unit = {},
) {
    val active = recording.meetingId == meeting.id
    var tab by rememberSaveable(meeting.id) { mutableIntStateOf(0) }
    var editTitle by remember { mutableStateOf(false) }
    var editText by remember { mutableStateOf<String?>(null) }
    var editUtterance by remember { mutableStateOf<Utterance?>(null) }
    var deleteConfirm by remember { mutableStateOf(false) }
    var seekTo by remember { mutableStateOf<Double?>(null) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Row(verticalAlignment = Alignment.Top) {
                Text(meeting.title, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.weight(1f))
                IconButton(onClick = { editTitle = true }, enabled = !aiBusy) { Icon(Icons.Outlined.Edit, "회의 이름 수정", tint = Muted) }
            }
            Text(dateLabel(meeting.startedAt), color = Muted, style = MaterialTheme.typography.bodyMedium)
            if (meeting.status == "example") { Spacer(Modifier.height(8.dp)); SmallTag("사용법 확인을 위한 가상 예시") }
            if (meeting.status == "interrupted") {
                Spacer(Modifier.height(8.dp)); Text("녹음이 중단되어 남아 있는 데이터를 보관했습니다. 재생하여 내용을 확인해 주세요.", color = MaterialTheme.colorScheme.error)
            }
        }
        if (active) item {
            RecordingCard(recording, onCommand)
        } else if (audio?.exists() == true) item {
            AudioPlayer(audio, meeting.durationSeconds, seekTo, onSeekHandled = { seekTo = null })
        }
        if (!active && !meeting.deleted) item {
            SpeechModeSelector(speechMode, onSpeechMode, enabled = !aiBusy)
            Text(if (speechMode == SpeechMode.LOCAL) "녹음을 태블릿에서 처리 · 서버 전송 없음" else "선택한 서버로 전송 · 실행 전 확인", color = Muted, style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (audio?.exists() == true) OutlinedButton(onClick = { onAI(true) }, enabled = !aiBusy, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Outlined.GraphicEq, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(if (speechMode == SpeechMode.LOCAL) "로컬 전사" else "서버 전사")
                }
                OutlinedButton(onClick = { onAI(false) }, enabled = !aiBusy && meeting.utterances.isNotEmpty(), modifier = Modifier.weight(1f)) {
                    Icon(Icons.Outlined.AutoAwesome, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("서버 회의록")
                }
            }
            if (hasLocalProposal) TextButton(onClick = onLocalProposal, enabled = !aiBusy) { Text("보관된 로컬 전사 결과 검토") }
        }
        item {
            TabRow(selectedTabIndex = tab, containerColor = Paper) {
                listOf("녹취 ${meeting.utterances.size}", "회의록", "메모").forEachIndexed { index, label ->
                    Tab(selected = tab == index, onClick = { tab = index }, text = { Text(label) })
                }
            }
        }
        when (tab) {
            0 -> {
                if (meeting.utterances.isEmpty()) item {
                    Surface(color = Color.White, shape = RoundedCornerShape(18.dp)) {
                        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Icon(Icons.Outlined.Forum, null, tint = Forest)
                            Text(if (active) "녹음 중에도 발언을 메모하세요" else "대화를 글로 남겨보세요", style = MaterialTheme.typography.titleMedium)
                            Text(if (active) "음성을 먼저 저장합니다. 녹음 종료 후 로컬 또는 서버 전사를 선택할 수 있습니다." else "로컬 또는 서버에서 녹음을 전사하거나 직접 발언을 추가하세요. 화자 이름은 직접 지정합니다.", color = Muted)
                        }
                    }
                }
                items(meeting.utterances, key = { it.id }) { u ->
                    Surface(color = Color.White, shape = RoundedCornerShape(16.dp), border = BorderStroke(1.dp, Color(0xFFE6EBE3))) {
                        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                SmallTag(u.speaker)
                                TextButton(onClick = { seekTo = u.start }, enabled = !active && audio?.exists() == true) {
                                    Text(timeLabel(u.start), fontFamily = FontFamily.Monospace)
                                }
                                Spacer(Modifier.weight(1f))
                                IconButton(onClick = { editUtterance = u }, enabled = !meeting.deleted && !aiBusy, modifier = Modifier.size(40.dp)) {
                                    Icon(Icons.Outlined.Edit, "발언 ${u.id} 수정", Modifier.size(18.dp), tint = Muted)
                                }
                            }
                            Text(u.text, style = MaterialTheme.typography.bodyLarge)
                        }
                    }
                }
                if (!meeting.deleted) item {
                    OutlinedButton(onClick = {
                        val time = if (active) recording.seconds else (meeting.utterances.lastOrNull()?.end ?: 0.0)
                        editUtterance = Utterance((meeting.utterances.maxOfOrNull { it.id } ?: 0) + 1, start = time, end = time, text = "")
                    }, modifier = Modifier.fillMaxWidth(), enabled = !aiBusy) {
                        Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(6.dp)); Text("발언 추가")
                    }
                }
            }
            1, 2 -> item {
                val value = if (tab == 1) meeting.minutes else meeting.notes
                Surface(color = Color.White, shape = RoundedCornerShape(18.dp)) {
                    Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(if (tab == 1) "회의록" else "회의 메모", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                            if (!meeting.deleted) TextButton(onClick = { editText = value }, enabled = !aiBusy) { Text("편집") }
                        }
                        if (value.isBlank()) {
                            Text(if (tab == 1) "결정 사항과 다음 할 일을 정리하세요. 양식으로 시작하거나 녹취에서 AI 초안을 만들 수 있습니다." else "안건, 참석자, 기억할 내용을 자유롭게 적어두세요.", color = Muted)
                            if (tab == 1 && !meeting.deleted) OutlinedButton(onClick = { editText = MeetingCodec.minutesTemplate(meeting) }, enabled = !aiBusy) { Text("회의록 양식으로 시작") }
                        } else Text(value, style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        }
        if (!active && !meeting.deleted) item {
            TextButton(onClick = { deleteConfirm = true }, enabled = !aiBusy) { Icon(Icons.Outlined.DeleteOutline, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("휴지통으로 이동") }
        }
    }
    if (editTitle) TextEditDialog("회의 이름", meeting.title, singleLine = true, onDismiss = { editTitle = false }) { text ->
        if (text.isNotBlank()) { onEdit { it.copy(title = text.trim().take(500)) }; editTitle = false }
    }
    editText?.let { text -> TextEditDialog(if (tab == 1) "회의록 편집" else "메모 편집", text, onDismiss = { editText = null }) { updated ->
        if (tab == 1) onEdit { it.copy(minutes = updated) } else onEdit { it.copy(notes = updated) }
        editText = null
    } }
    editUtterance?.let { u -> UtteranceDialog(u, onDismiss = { editUtterance = null }, onSave = { updated ->
        onEdit { m -> m.copy(utterances = (m.utterances.filterNot { it.id == updated.id } + updated).sortedWith(compareBy({ it.start }, { it.id }))) }
        editUtterance = null
    }) }
    if (deleteConfirm) AlertDialog(onDismissRequest = { deleteConfirm = false }, title = { Text("휴지통으로 옮길까요?") },
        text = { Text("녹음과 기록은 보관되며 목록의 휴지통에서 복원할 수 있습니다.") },
        confirmButton = { TextButton(onClick = { deleteConfirm = false; onDelete() }) { Text("이동") } },
        dismissButton = { TextButton(onClick = { deleteConfirm = false }) { Text("취소") } })
}

@Composable private fun RecordingCard(state: RecordingState, command: (String) -> Unit) {
    val levels = remember { mutableStateListOf<Float>() }
    LaunchedEffect(state.seconds) { levels += state.level; if (levels.size > 48) levels.removeAt(0) }
    Surface(color = Forest, shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(if (state.paused) "일시정지" else "●  녹음 중", color = Color(0xFFE0EEDD), style = MaterialTheme.typography.labelLarge)
            Text(timeLabel(state.seconds), color = Color.White, fontSize = 42.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium)
            Canvas(Modifier.fillMaxWidth().height(44.dp)) {
                levels.forEachIndexed { i, value ->
                    val x = size.width * i / 48
                    val h = (value * size.height * 2).coerceIn(2f, size.height)
                    drawLine(Color(0xFFA9D6B4), Offset(x, (size.height - h) / 2), Offset(x, (size.height + h) / 2), strokeWidth = 3.dp.toPx(), cap = StrokeCap.Round)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FilledTonalButton(onClick = { command(if (state.paused) RecordingService.RESUME else RecordingService.PAUSE) }, modifier = Modifier.weight(1f)) {
                    Icon(if (state.paused) Icons.Outlined.PlayArrow else Icons.Outlined.Pause, null); Spacer(Modifier.width(4.dp)); Text(if (state.paused) "재개" else "일시정지")
                }
                Button(onClick = { command(RecordingService.STOP) }, colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Forest), modifier = Modifier.weight(1f)) {
                    Icon(Icons.Outlined.Stop, null); Spacer(Modifier.width(4.dp)); Text("저장")
                }
            }
            Text("화면을 꺼도 녹음이 이어집니다", color = Color(0xFFD1E1D5), style = MaterialTheme.typography.labelMedium)
        }
    }
}

@Composable private fun AudioPlayer(file: File, duration: Double, seek: Double?, onSeekHandled: () -> Unit) {
    var player by remember(file.path) { mutableStateOf<MediaPlayer?>(null) }
    var playing by remember { mutableStateOf(false) }
    var position by remember { mutableFloatStateOf(0f) }
    var error by remember { mutableStateOf<String?>(null) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(file.path) {
        val p = MediaPlayer()
        p.setOnPreparedListener { player = it }
        p.setOnCompletionListener { playing = false; position = 0f; it.seekTo(0) }
        p.setOnErrorListener { _, _, _ -> error = "녹음 파일을 재생할 수 없습니다."; playing = false; true }
        runCatching { p.setDataSource(file.path); p.prepareAsync() }.onFailure { error = "녹음 파일을 열 수 없습니다." }
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) { if (playing) p.pause(); playing = false } }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); player = null; p.release() }
    }
    LaunchedEffect(playing) { while (playing) { position = (player?.currentPosition ?: 0) / 1000f; delay(200) } }
    LaunchedEffect(seek, player) {
        if (seek != null && player != null) { player?.seekTo((seek * 1000).toInt()); position = seek.toFloat(); onSeekHandled() }
    }
    Surface(color = Color.White, shape = RoundedCornerShape(18.dp)) {
        Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FilledIconButton(onClick = { player?.let { if (playing) it.pause() else it.start(); playing = !playing } }, enabled = player != null && error == null) {
                    Icon(if (playing) Icons.Outlined.Pause else Icons.Outlined.PlayArrow, if (playing) "재생 일시정지" else "녹음 재생")
                }
                Spacer(Modifier.width(12.dp))
                Column { Text("회의 녹음", fontWeight = FontWeight.SemiBold); Text("${timeLabel(position.toDouble())} / ${timeLabel(duration)}", color = Muted, fontFamily = FontFamily.Monospace) }
            }
            Slider(value = position.coerceIn(0f, duration.toFloat().coerceAtLeast(1f)), onValueChange = { position = it; player?.seekTo((it * 1000).toInt()) },
                valueRange = 0f..duration.toFloat().coerceAtLeast(1f), enabled = player != null && error == null)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable private fun UtteranceDialog(initial: Utterance, onDismiss: () -> Unit, onSave: (Utterance) -> Unit) {
    var speaker by rememberSaveable { mutableStateOf(initial.speaker) }
    var text by rememberSaveable { mutableStateOf(initial.text) }
    var start by rememberSaveable { mutableStateOf(initial.start.toString()) }
    var end by rememberSaveable { mutableStateOf(initial.end.toString()) }
    val s = start.toDoubleOrNull(); val e = end.toDoubleOrNull()
    val valid = !text.isBlank() && !speaker.isBlank() && s != null && e != null && s.isFinite() && e.isFinite() && s >= 0 && e >= s
    AlertDialog(onDismissRequest = onDismiss, title = { Text(if (initial.text.isBlank()) "발언 추가" else "발언 수정") },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(speaker, { speaker = it }, label = { Text("화자 이름") }, singleLine = true)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(start, { start = it }, label = { Text("시작 (초)") }, modifier = Modifier.weight(1f), singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                OutlinedTextField(end, { end = it }, label = { Text("종료 (초)") }, modifier = Modifier.weight(1f), singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
            }
            OutlinedTextField(text, { text = it }, label = { Text("발언 내용") }, minLines = 4, maxLines = 10)
            if (!valid) Text("이름·내용을 입력하고 종료 시각을 시작 이후로 지정해 주세요.", style = MaterialTheme.typography.bodySmall, color = Muted)
        } }, confirmButton = { Button(onClick = { onSave(initial.copy(speaker = speaker.trim(), text = text.trim(), start = s!!, end = e!!)) }, enabled = valid) { Text("저장") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("취소") } })
}
