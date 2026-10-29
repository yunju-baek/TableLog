package work.yunju.tablelog.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import work.yunju.tablelog.TableLogViewModel
import work.yunju.tablelog.ai.*
import work.yunju.tablelog.audio.RecordingService
import work.yunju.tablelog.data.Meeting

@Composable fun AssistantDialog(vm: TableLogViewModel, meeting: Meeting, onDismiss: () -> Unit) {
    var prompt by rememberSaveable(meeting.id) { mutableStateOf("") }
    var pending by remember { mutableStateOf<Pair<MeetingAction, AISettings>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val recording by RecordingService.state.collectAsState()
    val locked = vm.busy != null
    fun request(task: MeetingAction) {
        runCatching { vm.settingsStore.read().also { it.validate(); require(it.textModel.isNotBlank()) { "설정에서 회의 AI 모델을 선택해 주세요." } } }
            .onSuccess { pending = task to it }.onFailure { error = it.message }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxWidth().widthIn(max = 900.dp).fillMaxHeight(.95f).padding(16.dp), shape = MaterialTheme.shapes.extraLarge) {
            Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("회의 AI", style = MaterialTheme.typography.headlineMedium)
                Text("현재 녹취·메모·참고자료를 바탕으로 처리합니다. 교정과 회의록 교체는 결과를 검토한 뒤 적용합니다.", color = Muted)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { request(MeetingAction.SUMMARY) }, enabled = !locked && meeting.utterances.isNotEmpty()) { Text("지금 요약") }
                    OutlinedButton(onClick = { request(MeetingAction.MINUTES) }, enabled = !locked && meeting.utterances.isNotEmpty() && !recording.running) { Text("회의록 생성") }
                    OutlinedButton(onClick = { request(MeetingAction.CORRECT) }, enabled = !locked && meeting.utterances.isNotEmpty() && !recording.running) { Text("녹취 교정") }
                }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (meeting.summary.isNotBlank()) { Text("진행 요약", style = MaterialTheme.typography.titleMedium); Text(meeting.summary); HorizontalDivider() }
                    if (meeting.assistant.isEmpty()) Text("예: 누가 무엇을 언제까지 하기로 했나요?\n교정 요청 예: 고유명사는 유지하고 띄어쓰기만 고쳐줘.", color = Muted)
                    meeting.assistant.forEach { turn ->
                        Text(turn.question, style = MaterialTheme.typography.titleMedium, color = Forest)
                        Text(turn.answer); HorizontalDivider()
                    }
                }
                OutlinedTextField(prompt, { prompt = it.take(2000) }, modifier = Modifier.fillMaxWidth(), maxLines = 4, label = { Text("질문 또는 교정 요청") }, enabled = !locked)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (locked) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text(vm.busy.orEmpty()) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = onDismiss) { Text("닫기") }
                    if (locked) TextButton(onClick = vm::cancelAI) { Text("요청 취소") }
                    Spacer(Modifier.weight(1f))
                    Button(onClick = { request(MeetingAction.QUESTION) }, enabled = !locked && prompt.isNotBlank() && meeting.utterances.isNotEmpty()) { Text("질문하기") }
                }
            }
        }
    }
    pending?.let { (task, settings) -> AlertDialog(onDismissRequest = { pending = null }, title = { Text(task.label) },
        text = { Text("녹취·메모·참고자료와 입력한 요청을 다음 서버로 전송합니다.\n\n${settings.canonicalUrl()}") },
        confirmButton = { Button(onClick = {
            pending = null; vm.requestText(meeting, task, prompt, settings)
            if (task == MeetingAction.CORRECT || task == MeetingAction.MINUTES) onDismiss()
        }) { Text("전송하고 실행") } }, dismissButton = { TextButton(onClick = { pending = null }) { Text("취소") } }) }
}
