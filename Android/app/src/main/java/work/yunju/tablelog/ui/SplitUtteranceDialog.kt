package work.yunju.tablelog.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import work.yunju.tablelog.data.Utterance

@Composable fun SplitUtteranceDialog(u: Utterance, onDismiss: () -> Unit, onSave: (Double, String, String) -> Unit) {
    var first by remember { mutableStateOf(u.text) }
    var second by remember { mutableStateOf("") }
    var position by remember { mutableStateOf(((u.start + u.end) / 2).toString()) }
    val time = position.toDoubleOrNull()
    AlertDialog(onDismissRequest = onDismiss, title = { Text("발언 분리") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("원문을 두 문장으로 나누고 녹음 시각을 지정하세요. 원문은 변경 이력에 보관합니다.")
            OutlinedTextField(position, { position = it }, label = { Text("분리 시각 (초) · ${u.start}~${u.end}") }, singleLine = true)
            OutlinedTextField(first, { first = it }, label = { Text("앞 발언") }, minLines = 3)
            OutlinedTextField(second, { second = it }, label = { Text("뒤 발언") }, minLines = 3)
        }
    }, confirmButton = { Button(onClick = { onSave(time!!, first, second) }, enabled = time != null && time > u.start && time < u.end && first.isNotBlank() && second.isNotBlank()) { Text("분리하여 저장") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("취소") } })
}
