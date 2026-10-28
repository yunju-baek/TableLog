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

@Composable fun SettingsDialog(store: SettingsStore, onDismiss: () -> Unit, onMessage: (String) -> Unit) {
    val initial = remember { runCatching { store.read() } }
    var url by remember { mutableStateOf(initial.getOrNull()?.baseUrl.orEmpty()) }
    var speech by remember { mutableStateOf(initial.getOrNull()?.speechModel.orEmpty()) }
    var model by remember { mutableStateOf(initial.getOrNull()?.textModel.orEmpty()) }
    // The API key is intentionally excluded from saved instance state.
    var key by remember { mutableStateOf(initial.getOrNull()?.apiKey.orEmpty()) }
    var error by remember { mutableStateOf(if (initial.isFailure) "저장된 인증 정보를 읽지 못했습니다. 다시 입력하거나 연결 설정을 지워 주세요." else null) }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxWidth().padding(16.dp).heightIn(max = 780.dp), shape = MaterialTheme.shapes.extraLarge) {
            Column(Modifier.padding(24.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("AI 연결 설정", style = MaterialTheme.typography.headlineMedium)
                Text("녹음·편집·내보내기는 서버 없이 사용할 수 있습니다. AI 기능을 사용하려면 음성 전사와 채팅 API를 지원하는 서버를 연결하세요.", color = Muted)
                OutlinedTextField(url, { url = it }, modifier = Modifier.fillMaxWidth(), label = { Text("서버 기본 주소 (HTTPS)") }, placeholder = { Text("https://서버주소/v1") }, singleLine = true)
                OutlinedTextField(speech, { speech = it }, modifier = Modifier.fillMaxWidth(), label = { Text("음성 모델 이름") }, singleLine = true)
                OutlinedTextField(model, { model = it }, modifier = Modifier.fillMaxWidth(), label = { Text("회의록 모델 이름") }, singleLine = true)
                OutlinedTextField(key, { key = it }, modifier = Modifier.fillMaxWidth(), label = { Text("API 키 (서버가 요구하는 경우)") }, singleLine = true, visualTransformation = PasswordVisualTransformation())
                Text("키는 이 기기의 보안 키로 암호화해 보관합니다. 자료는 AI 기능 실행 전 전송 확인을 거칩니다. Mac의 CLI 로그인은 이 앱과 공유되지 않습니다.", style = MaterialTheme.typography.bodyMedium, color = Muted)
                HorizontalDivider()
                Text("테이블로그 Android 0.1.0", style = MaterialTheme.typography.titleMedium)
                Text("현재 지원: 녹음·일시정지·재생, 녹취 가져오기, 발언·화자 이름 편집, 회의록·메모, 휴지통, 내보내기, 선택적 AI 서버 연결.\n\n휴대폰 내 음성 모델·자동 화자 인식·Mac 자동 동기화는 포함되지 않습니다. 앱 삭제 시 기기의 기록도 삭제되므로 필요한 자료는 내보내세요.", style = MaterialTheme.typography.bodyMedium, color = Muted)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { runCatching { store.clear() }.onSuccess { onMessage("AI 연결 설정을 지웠습니다."); onDismiss() }.onFailure { error = it.message } }) { Text("연결 지우기") }
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onDismiss) { Text("닫기") }
                    Button(onClick = {
                        runCatching { store.save(AISettings(url, speech, model, key)) }
                            .onSuccess { onMessage("설정을 저장했습니다."); onDismiss() }.onFailure { error = it.message }
                    }) { Text("저장") }
                }
            }
        }
    }
}

@Composable fun ProposalDialog(proposal: AIProposal, onDismiss: () -> Unit, onApply: () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize().padding(16.dp), shape = MaterialTheme.shapes.extraLarge) {
            Column(Modifier.padding(24.dp)) {
                Text("AI 결과 검토", style = MaterialTheme.typography.headlineMedium)
                Spacer(Modifier.height(12.dp))
                Text("내용과 화자 이름을 확인하세요. 적용하면 현재 ${if (proposal.minutes != null) "회의록" else "녹취"}을 교체하고, 이전 내용은 변경 이력 파일로 보관합니다.", color = Muted)
                Spacer(Modifier.height(16.dp))
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                    if (proposal.minutes != null) Text(proposal.minutes)
                    proposal.utterances?.forEach {
                        Text("${timeLabel(it.start)} · ${it.speaker}", color = Forest, style = MaterialTheme.typography.labelLarge)
                        Text(it.text, Modifier.padding(top = 6.dp, bottom = 18.dp))
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
