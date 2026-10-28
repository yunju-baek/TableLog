package work.yunju.tablelog.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import work.yunju.tablelog.TableLogViewModel
import work.yunju.tablelog.audio.RecordingService
import work.yunju.tablelog.data.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun TableLogApp(vm: TableLogViewModel) = TableLogTheme {
    val context = LocalContext.current
    val meetings by vm.repository.meetings.collectAsStateWithLifecycle()
    val ready by vm.app.ready.collectAsStateWithLifecycle()
    val recording by RecordingService.state.collectAsStateWithLifecycle()
    val warning by vm.repository.warning.collectAsStateWithLifecycle()
    val selected = meetings.find { it.id == vm.selectedId }
    var newMeeting by rememberSaveable { mutableStateOf(false) }
    var title by rememberSaveable { mutableStateOf("") }
    var settings by rememberSaveable { mutableStateOf(false) }
    var showTrash by rememberSaveable { mutableStateOf(false) }
    var exportMenu by remember { mutableStateOf(false) }
    var exportText by rememberSaveable { mutableStateOf("") }
    var aiConsent by remember { mutableStateOf<Pair<Meeting, Boolean>?>(null) }
    var aiHost by remember { mutableStateOf("") }
    val snackbar = remember { SnackbarHostState() }
    fun service(action: String) {
        try {
            val intent = Intent(context, RecordingService::class.java).setAction(action).putExtra("title", title)
            if (action == RecordingService.START) ContextCompat.startForegroundService(context, intent)
            else context.startService(intent)
        } catch (e: Exception) { vm.message = "녹음 명령을 실행하지 못했습니다. ${e.message.orEmpty()}" }
    }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted[Manifest.permission.RECORD_AUDIO] == true || ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) service(RecordingService.START)
        else vm.message = "녹음하려면 마이크 권한을 허용해 주세요. 기기 설정 → 앱 → 테이블로그 → 권한에서 변경할 수 있습니다."
    }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { it?.let(vm::import) }
    val markdownExporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/markdown")) { it?.let { uri -> vm.export(uri, exportText) } }
    val jsonExporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { it?.let { uri -> vm.export(uri, exportText) } }

    LaunchedEffect(recording.meetingId) { recording.meetingId?.let { vm.selectedId = it } }
    LaunchedEffect(recording.error) { recording.error?.let { vm.message = it } }
    LaunchedEffect(warning) { warning?.let { vm.message = it } }
    LaunchedEffect(vm.message) { vm.message?.let { snackbar.showSnackbar(it); vm.message = null } }
    BackHandler(selected != null && !settings) { vm.selectedId = null }

    Scaffold(containerColor = Paper, snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(title = {
                Text(if (selected == null) "테이블로그" else "회의 기록", fontWeight = FontWeight.Bold)
            }, navigationIcon = {
                if (selected != null) IconButton(onClick = { vm.selectedId = null }) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "회의 목록") }
            }, actions = {
                if (selected == null) {
                    IconButton(onClick = { showTrash = !showTrash }) { Icon(if (showTrash) Icons.Outlined.Folder else Icons.Outlined.DeleteOutline, if (showTrash) "회의 목록" else "휴지통") }
                } else {
                    Box {
                        IconButton(onClick = { exportMenu = true }) { Icon(Icons.Outlined.IosShare, "내보내기") }
                        DropdownMenu(expanded = exportMenu, onDismissRequest = { exportMenu = false }) {
                            DropdownMenuItem(text = { Text("Markdown 저장") }, onClick = {
                                exportMenu = false; exportText = MeetingCodec.markdown(selected)
                                markdownExporter.launch("TableLog-${selected.id.take(8)}.md")
                            })
                            DropdownMenuItem(text = { Text("Mac용 녹취 JSON 저장") }, onClick = {
                                exportMenu = false; exportText = MeetingCodec.desktopTranscript(selected)
                                jsonExporter.launch("TableLog-${selected.id.take(8)}.json")
                            })
                            DropdownMenuItem(text = { Text("Android 기록 JSON 백업") }, onClick = {
                                exportMenu = false; exportText = MeetingCodec.encode(selected)
                                jsonExporter.launch("TableLog-android-${selected.id.take(8)}.json")
                            })
                            DropdownMenuItem(text = { Text("녹음 WAV 공유") }, enabled = selected.audioName != null && recording.meetingId != selected.id, onClick = {
                                exportMenu = false
                                runCatching {
                                    val file = vm.repository.audioFile(selected) ?: error("녹음 파일이 없습니다.")
                                    check(file.exists()) { "녹음 파일이 없습니다." }
                                    val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                                    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("audio/wav")
                                        .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), "녹음 공유"))
                                }.onFailure { vm.message = it.message }
                            })
                        }
                    }
                }
                IconButton(onClick = { settings = true }) { Icon(Icons.Outlined.Settings, "설정") }
            }, colors = TopAppBarDefaults.topAppBarColors(containerColor = Paper))
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            vm.busy?.let { progress ->
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(progress, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    if (!progress.startsWith("녹취 가져")) TextButton(onClick = vm::cancelAI) { Text("취소") }
                }
            }
            if (!ready) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            else if (selected == null) HomeScreen(meetings, showTrash, recording.meetingId,
                onOpen = { vm.selectedId = it }, onRecord = { title = ""; newMeeting = true },
                onImport = { importer.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }, onExample = vm::addExample,
                onRestore = { id -> vm.edit(id) { it.copy(deleted = false) } }, busy = vm.busy != null)
            else MeetingScreen(selected, recording, vm.repository.audioFile(selected),
                onCommand = ::service, onEdit = { change -> vm.edit(selected.id, change) },
                onDelete = { vm.edit(selected.id) { it.copy(deleted = true) }; vm.selectedId = null },
                onAI = { speech ->
                    runCatching { vm.settingsStore.read().also { it.validate() } }
                        .onSuccess { aiHost = it.baseUrl; aiConsent = selected to speech }
                        .onFailure { settings = true; vm.message = "먼저 AI 서버 주소와 모델 이름을 설정해 주세요." }
                }, aiBusy = vm.busy != null)
        }
    }
    if (newMeeting) AlertDialog(onDismissRequest = { newMeeting = false },
        icon = { Icon(Icons.Outlined.Mic, null) }, title = { Text("새 회의 녹음") },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("회의 이름을 정하고 녹음을 시작하세요. 녹음 중에는 알림에서 일시정지하거나 종료할 수 있습니다.")
            OutlinedTextField(value = title, onValueChange = { title = it.take(500) }, label = { Text("회의 이름") }, singleLine = true)
        } }, confirmButton = { Button(onClick = {
            newMeeting = false
            val request = mutableListOf(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) request += Manifest.permission.POST_NOTIFICATIONS
            permissions.launch(request.toTypedArray())
        }) { Text("녹음 시작") } }, dismissButton = { TextButton(onClick = { newMeeting = false }) { Text("취소") } })
    if (settings) SettingsDialog(vm.settingsStore, onDismiss = { settings = false }, onMessage = { vm.message = it })
    aiConsent?.let { (m, speech) -> AlertDialog(onDismissRequest = { aiConsent = null },
        title = { Text(if (speech) "음성을 전사할까요?" else "회의록을 작성할까요?") },
        text = { Text("${if (speech) "이 회의의 녹음 파일" else "이 회의의 제목·일시·녹취·메모"}을 다음 서버로 전송합니다. 서버의 이용 요금과 데이터 처리 정책이 적용됩니다.\n\n$aiHost\n\n완료 후 결과를 검토하고 적용할 수 있습니다.") },
        confirmButton = { Button(onClick = { aiConsent = null; vm.requestAI(m, speech) }) { Text("전송하고 시작") } },
        dismissButton = { TextButton(onClick = { aiConsent = null }) { Text("취소") } }) }
    vm.proposal?.let { p -> ProposalDialog(p, onDismiss = { vm.proposal = null }, onApply = { vm.applyProposal() }) }
}

@Composable private fun HomeScreen(
    all: List<Meeting>, trash: Boolean, recordingId: String?, onOpen: (String) -> Unit,
    onRecord: () -> Unit, onImport: () -> Unit, onExample: () -> Unit, onRestore: (String) -> Unit, busy: Boolean,
) {
    var query by rememberSaveable { mutableStateOf("") }
    val meetings = all.filter { it.deleted == trash && (it.title.contains(query, true) || it.utterances.any { u -> u.text.contains(query, true) }) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Text(if (trash) "휴지통" else "대화가 남기는 기록", style = MaterialTheme.typography.headlineLarge)
            Spacer(Modifier.height(7.dp))
            Text(if (trash) "보관한 회의는 언제든 복원할 수 있습니다." else "회의의 시작부터, 다음 할 일까지.", color = Muted)
        }
        if (!trash) item {
            Surface(color = Forest, shape = RoundedCornerShape(24.dp)) {
                Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.GraphicEq, null, tint = Color(0xFFCFE4CF), modifier = Modifier.size(32.dp))
                        Spacer(Modifier.width(10.dp)); Text("RECORD · REMEMBER", color = Color(0xFFCFE4CF), style = MaterialTheme.typography.labelMedium)
                    }
                    Text(if (recordingId != null) "진행 중인 회의가 있어요" else "지금, 이야기를 담아보세요", color = Color.White, style = MaterialTheme.typography.titleLarge)
                    Text("녹음과 메모를 한곳에 보관하고\n필요한 순간 다시 꺼내보세요.", color = Color(0xFFD8E7DF))
                    Button(onClick = { if (recordingId != null) onOpen(recordingId) else onRecord() }, enabled = !busy,
                        colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Forest), modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                        Icon(Icons.Outlined.Mic, null); Spacer(Modifier.width(8.dp)); Text(if (recordingId != null) "녹음 화면으로" else "새 회의 녹음", fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(if (trash) "보관된 회의" else "나의 회의", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                if (!trash) TextButton(onClick = onImport, enabled = !busy) { Icon(Icons.Outlined.FileOpen, null, Modifier.size(18.dp)); Spacer(Modifier.width(5.dp)); Text("녹취 가져오기") }
            }
            OutlinedTextField(value = query, onValueChange = { query = it }, modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("회의 이름이나 발언 검색") }, leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true, shape = RoundedCornerShape(16.dp))
        }
        if (meetings.isEmpty()) item {
            Column(Modifier.fillMaxWidth().padding(vertical = 28.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Outlined.FolderOpen, null, Modifier.size(38.dp), tint = Muted)
                Text(if (query.isNotBlank()) "검색 결과가 없습니다" else if (trash) "휴지통이 비어 있습니다" else "첫 회의를 기다리고 있어요", fontWeight = FontWeight.SemiBold)
                if (!trash && query.isBlank()) {
                    Text("새로 녹음하거나 Mac의 녹취 JSON을 가져오세요.", style = MaterialTheme.typography.bodyMedium, color = Muted)
                    TextButton(onClick = onExample, enabled = !busy) { Text("예시 회의 둘러보기") }
                }
            }
        }
        items(meetings, key = { it.id }) { m ->
            Card(onClick = { onOpen(m.id) }, shape = RoundedCornerShape(18.dp), colors = CardDefaults.cardColors(containerColor = Color.White),
                border = BorderStroke(1.dp, Color(0xFFE3E9E1))) {
                Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Description, null, tint = Forest, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(8.dp)); Text(m.title, modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold)
                    }
                    Text("${dateLabel(m.startedAt)} · ${timeLabel(m.durationSeconds)}", style = MaterialTheme.typography.bodyMedium, color = Muted)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        SmallTag(when { m.id == recordingId -> "녹음 중"; m.status == "interrupted" -> "중단된 녹음"; m.status == "example" -> "가상 예시"; m.utterances.isEmpty() -> "녹음 보관"; else -> "발언 ${m.utterances.size}개" })
                        if (m.minutes.isNotBlank()) SmallTag("회의록")
                        if (trash) TextButton(onClick = { onRestore(m.id) }, contentPadding = PaddingValues(horizontal = 12.dp)) { Text("복원") }
                    }
                }
            }
        }
        item { Text("기기에 저장되는 나만의 회의 노트", style = MaterialTheme.typography.labelMedium, color = Muted, modifier = Modifier.padding(vertical = 12.dp)) }
    }
}

@Composable fun SmallTag(text: String) {
    Surface(color = Color(0xFFEAF1E9), shape = RoundedCornerShape(6.dp)) {
        Text(text, Modifier.padding(horizontal = 8.dp, vertical = 4.dp), style = MaterialTheme.typography.labelMedium, color = Forest)
    }
}
