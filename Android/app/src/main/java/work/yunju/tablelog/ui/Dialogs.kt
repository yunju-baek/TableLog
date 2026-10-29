package work.yunju.tablelog.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import work.yunju.tablelog.AIProposal
import work.yunju.tablelog.ai.*
import work.yunju.tablelog.data.timeLabel

@Composable fun TextEditDialog(title: String, initial: String, singleLine: Boolean = false, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf(initial) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(title) }, text = {
        OutlinedTextField(text, { text = it }, modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp),
            singleLine = singleLine, minLines = if (singleLine) 1 else 8, label = { Text("내용") })
    }, confirmButton = { Button(onClick = { onSave(text) }, enabled = !singleLine || text.isNotBlank()) { Text("저장") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("취소") } })
}

@Composable fun SettingsDialog(vm: work.yunju.tablelog.TableLogViewModel, onDismiss: () -> Unit) {
    val store = vm.settingsStore
    val initial = remember { runCatching { store.read() } }
    val local by LocalAiService.state.collectAsState()
    val scope = rememberCoroutineScope()
    var url by remember { mutableStateOf(initial.getOrNull()?.baseUrl.orEmpty()) }
    var speech by remember { mutableStateOf(initial.getOrNull()?.speechModel.orEmpty()) }
    var model by remember { mutableStateOf(initial.getOrNull()?.textModel.orEmpty()) }
    // Credentials never enter saved instance state. Changing the endpoint clears the draft token.
    var key by remember { mutableStateOf(initial.getOrNull()?.apiKey.orEmpty()) }
    var error by remember { mutableStateOf(if (initial.isFailure) "저장된 인증 정보를 읽지 못했습니다. 다시 등록하거나 연결을 지워 주세요." else null) }
    var connection by remember { mutableStateOf<String?>(null) }
    var checking by remember { mutableStateOf(false) }
    var pairingCode by remember { mutableStateOf("") }
    val recording by work.yunju.tablelog.audio.RecordingService.state.collectAsState()
    val locked = local.running || vm.busy != null || checking || recording.running
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.widthIn(max = 720.dp).fillMaxWidth().padding(16.dp).heightIn(max = 850.dp), shape = MaterialTheme.shapes.extraLarge) {
            Column(Modifier.padding(24.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("전사와 서버 설정", style = MaterialTheme.typography.headlineMedium)
                SpeechModeSelector(vm.speechMode, vm::chooseSpeechMode, enabled = !locked)
                Text(if (vm.speechMode == SpeechMode.LOCAL) "녹음은 이 태블릿에서 처리합니다. 서버로 자동 전환하지 않습니다." else "전사를 실행할 때 녹음 전송을 확인합니다. 서버 연결에 실패해도 녹음은 기기에 남습니다.", color = Muted)
                HorizontalDivider()
                ModelSettings(vm, locked)
                HorizontalDivider()
                Text("서버 연결", style = MaterialTheme.typography.titleLarge)
                OutlinedButton(onClick = {
                    if (AISettings(url).canonicalUrl() != ServerPairing.MAC_STUDIO_URL) key = ""
                    url = ServerPairing.MAC_STUDIO_URL; speech = ServerPairing.MAC_STUDIO_MODEL
                    model = ServerPairing.MAC_STUDIO_TEXT_MODEL; connection = null; error = null
                }, enabled = !locked) { Text("맥스튜디오 선택") }
                Text("맥스튜디오에서 음성 전사와 회의 요약·질문·교정을 처리합니다. 모델은 작업 후 메모리에서 해제합니다.", color = Muted)
                OutlinedTextField(pairingCode, { pairingCode = it }, modifier = Modifier.fillMaxWidth(), enabled = !locked,
                    label = { Text("맥에서 발급한 일회용 연결 코드") }, placeholder = { Text("ABCD-EFGH-JKLM") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation())
                Button(onClick = {
                    checking = true; error = null; connection = null
                    val target = url; val code = pairingCode
                    scope.launch {
                        try {
                            val paired = ServerPairing().connect(target, code)
                            store.save(paired)
                            url = paired.baseUrl; speech = paired.speechModel; model = paired.textModel; key = paired.apiKey
                            pairingCode = ""; vm.chooseSpeechMode(SpeechMode.SERVER)
                            connection = "맥스튜디오 연결을 저장했습니다. 기기 연결은 30일간 유효합니다."
                        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
                        catch (e: Exception) { error = e.message }
                        finally { checking = false }
                    }
                }, enabled = !locked && pairingCode.isNotBlank()) { Text("코드로 연결·저장") }
                Text("맥에서 Server/tablelog-server issue-code 명령으로 코드를 발급합니다. 다른 서버는 아래 주소와 기기 토큰을 직접 입력할 수 있습니다.", style = MaterialTheme.typography.bodySmall, color = Muted)
                Text("서버가 발급한 이 기기 전용 토큰을 등록하세요. 외부 AI 서비스의 키는 서버에서 관리하는 구성을 권장합니다.", color = Muted)
                OutlinedTextField(url, { next ->
                    if (AISettings(next).canonicalUrl() != AISettings(url).canonicalUrl()) key = ""
                    url = next; connection = null
                }, modifier = Modifier.fillMaxWidth(), enabled = !locked, label = { Text("서버 기본 주소 (HTTPS)") }, placeholder = { Text("https://서버주소/v1") }, singleLine = true)
                OutlinedTextField(key, { key = it; connection = null }, modifier = Modifier.fillMaxWidth(), enabled = !locked,
                    label = { Text("기기 인증 토큰") }, singleLine = true, visualTransformation = PasswordVisualTransformation())
                OutlinedTextField(speech, { speech = it }, modifier = Modifier.fillMaxWidth(), enabled = !locked, label = { Text("서버 음성 모델 이름") }, singleLine = true)
                OutlinedTextField(model, { model = it }, modifier = Modifier.fillMaxWidth(), enabled = !locked, label = { Text("서버 회의록 모델 이름") }, singleLine = true)
                Text("토큰은 기기의 보안 키로 암호화하고 이 서버 주소에 묶어 보관합니다. 주소를 바꾸면 새 토큰이 필요합니다. 연결 확인에는 음성·녹취를 보내지 않습니다.", style = MaterialTheme.typography.bodyMedium, color = Muted)
                OutlinedButton(onClick = {
                    checking = true; error = null; connection = null
                    val snapshot = AISettings(url, speech, model, key)
                    scope.launch {
                        try { connection = AIClient(snapshot).checkConnection() }
                        catch (e: kotlinx.coroutines.CancellationException) { throw e }
                        catch (e: Exception) { error = e.message }
                        finally { checking = false }
                    }
                }, enabled = !locked) { Text(if (checking) "연결 확인 중" else "서버 연결 확인") }
                connection?.let { Text(it, color = Forest) }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = {
                        runCatching { store.clear() }.onSuccess {
                            url = ""; speech = ""; model = ""; key = ""; connection = null
                            error = "기기에서 연결을 지웠습니다. 토큰 폐기는 서버의 기기 관리에서 처리해 주세요."
                        }.onFailure { error = it.message }
                    }, enabled = !locked) { Text("연결 지우기") }
                    Spacer(Modifier.weight(1f))
                    Button(onClick = {
                        runCatching { store.save(AISettings(url, speech, model, key)) }
                            .onSuccess { vm.message = "서버 연결을 저장했습니다."; onDismiss() }.onFailure { error = it.message }
                    }, enabled = !locked) { Text("서버 연결 저장") }
                }
                Text("Android 0.4.0 · 녹음 중 자동 전사와 종료 후 마무리를 지원합니다. 자동 화자 분리와 로컬 회의록 요약은 아직 제공하지 않습니다.", style = MaterialTheme.typography.bodySmall, color = Muted)
                TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text("닫기") }
            }
        }
    }

}

@Composable fun SpeechModeSelector(mode: SpeechMode, onSelect: (SpeechMode) -> Unit, enabled: Boolean) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SpeechMode.entries.forEach { choice ->
            FilterChip(selected = mode == choice, onClick = { onSelect(choice) }, enabled = enabled, label = { Text(choice.label) })
        }
    }
}

@Composable fun ProposalDialog(proposal: AIProposal, onDismiss: () -> Unit, onApply: () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize().padding(16.dp), shape = MaterialTheme.shapes.extraLarge) {
            Column(Modifier.padding(24.dp)) {
                Text("${proposal.source} 결과 검토", style = MaterialTheme.typography.headlineMedium)
                Spacer(Modifier.height(12.dp))
                Text("내용과 화자 이름을 확인하세요. 적용하면 현재 ${if (proposal.minutes != null) "회의록" else "녹취"}을 교체하고, 이전 내용은 변경 이력 파일로 보관합니다.", color = Muted)
                Spacer(Modifier.height(16.dp))
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                    if (proposal.minutes != null) Text(proposal.minutes)
                    proposal.utterances?.forEach {
                        Text("${timeLabel(it.start)} · ${it.speaker}", color = Forest, style = MaterialTheme.typography.labelLarge)
                        val before = proposal.original?.find { original -> original.id == it.id }?.text
                        if (before != null && before != it.text) Text("원문: $before", color = Muted, modifier = Modifier.padding(top = 6.dp))
                        Text(if (before != null && before != it.text) "교정: ${it.text}" else it.text, Modifier.padding(top = 6.dp, bottom = 18.dp))
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = onDismiss) { Text("닫기") }
                    Spacer(Modifier.width(8.dp)); Button(onClick = onApply) { Text("검토한 내용 적용") }
                }
            }
        }
    }
}
