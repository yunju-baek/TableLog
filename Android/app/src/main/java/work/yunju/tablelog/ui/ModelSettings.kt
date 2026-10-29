package work.yunju.tablelog.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import work.yunju.tablelog.TableLogViewModel
import work.yunju.tablelog.ai.*

@Composable fun ModelSettings(vm: TableLogViewModel, locked: Boolean) {
    val local by LocalAiService.state.collectAsState()
    val store = vm.localModels
    val model = store.definition
    val uri = LocalUriHandler.current
    var expanded by remember { mutableStateOf(false) }
    var install by remember { mutableStateOf(false) }
    var delete by remember { mutableStateOf(false) }
    Text("로컬 음성 모델", style = MaterialTheme.typography.titleLarge)
    Box {
        OutlinedButton(onClick = { expanded = true }, enabled = !locked, modifier = Modifier.fillMaxWidth()) {
            Text("${model.name} · ${model.sizeLabel} ▾")
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            store.catalog.forEach { choice ->
                val installed = LocalModelStore(vm.app, choice.id).installed()
                DropdownMenuItem(text = { Column {
                    Text(choice.name)
                    Text("${choice.sizeLabel} · ${if (installed) "설치됨" else "다운로드 필요"}", style = MaterialTheme.typography.bodySmall)
                } }, enabled = !locked, onClick = { expanded = false; vm.chooseModel(choice.id) })
            }
        }
    }
    Text(model.description, color = Muted)
    Text(if (store.installed()) "설치됨 · 인터넷 없이 사용 가능" else "${model.sizeLabel} 다운로드 필요 · 설치 중 녹음은 전송하지 않습니다.")
    Text("설치한 모델은 선택해서 바꿔 쓸 수 있습니다. 한 번에 하나만 실행하며, 전사가 끝나면 메모리에서 해제합니다. 큰 모델은 녹음보다 전사가 늦어질 수 있습니다.", color = Muted, style = MaterialTheme.typography.bodySmall)
    Text("인식 언어", style = MaterialTheme.typography.titleSmall)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf("auto" to "자동", "ko" to "한국어", "en" to "영어").forEach { (value, label) ->
            FilterChip(selected = store.language == value, onClick = { vm.chooseLanguage(value) }, enabled = !locked, label = { Text(label) })
        }
    }
    Text("한국어·영어가 섞인 회의는 자동을 선택하세요. 인식 언어에 따라 결과가 달라질 수 있습니다.", color = Muted, style = MaterialTheme.typography.bodySmall)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { install = true }, enabled = !locked) { Text(if (store.installed()) "모델 검사·복구" else "모델 다운로드") }
        TextButton(onClick = { delete = true }, enabled = !locked && store.hasFiles()) { Text("모델 삭제") }
    }
    if (local.running) {
        LinearProgressIndicator(Modifier.fillMaxWidth()); Text(local.message.orEmpty())
        TextButton(onClick = vm::cancelAI) { Text("로컬 작업 취소") }
    }
    TextButton(onClick = { uri.openUri(model.source) }) { Text("모델 출처·이용 조건") }
    Row {
        Column(Modifier.weight(1f)) { Text("녹음 중 자동 전사"); Text("종료하면 남은 구간까지 자동 처리", color = Muted, style = MaterialTheme.typography.bodySmall) }
        Switch(checked = vm.liveTranscription, onCheckedChange = vm::chooseLiveTranscription, enabled = !locked)
    }
    if (install) AlertDialog(onDismissRequest = { install = false }, title = { Text("${model.name} 설치") },
        text = { Text("Hugging Face와 GitHub에서 ${model.sizeLabel}를 내려받습니다. Wi-Fi 사용을 권장합니다. 중단해도 다음에 이어받습니다.\n\n다운로드 용량 외에 실행 메모리가 필요합니다. 특히 Medium은 고사양 태블릿에서 사용하세요.") },
        confirmButton = { Button(onClick = { install = false; vm.startLocal(true) }, enabled = !locked) { Text("다운로드") } },
        dismissButton = { TextButton(onClick = { install = false }) { Text("취소") } })
    if (delete) AlertDialog(onDismissRequest = { delete = false }, title = { Text("${model.name} 삭제") },
        text = { Text("선택한 모델과 이어받기 파일만 지웁니다. 녹음·녹취와 다른 모델은 보관합니다. 다시 사용하려면 다운로드가 필요합니다.") },
        confirmButton = { TextButton(onClick = { delete = false; vm.deleteModel() }, enabled = !locked) { Text("삭제") } },
        dismissButton = { TextButton(onClick = { delete = false }) { Text("취소") } })
}
