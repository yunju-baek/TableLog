package work.yunju.tablelog

import android.app.Application
import android.net.Uri
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import work.yunju.tablelog.ai.*
import work.yunju.tablelog.audio.RecordingService
import work.yunju.tablelog.data.*

data class AIProposal(val meetingId: String, val revision: Int, val utterances: List<Utterance>? = null, val minutes: String? = null, val source: String = "서버")

class TableLogViewModel(application: Application) : AndroidViewModel(application) {
    val app = application as TableLogApplication
    val repository = app.repository
    val settingsStore = SettingsStore(application)
    var speechMode by mutableStateOf(settingsStore.speechMode())
        private set
    val localModels = LocalModelStore(application)
    var selectedId by mutableStateOf<String?>(null)
    var message by mutableStateOf<String?>(null)
    var busy by mutableStateOf<String?>(null)
        private set
    var proposal by mutableStateOf<AIProposal?>(null)
    private var aiJob: Job? = null

    fun chooseSpeechMode(mode: SpeechMode) {
        if (busy != null || LocalAiService.state.value.running) return
        runCatching { settingsStore.setSpeechMode(mode); speechMode = mode }.onFailure { message = it.message }
    }
    fun startLocal(install: Boolean, meeting: Meeting? = null) {
        if (busy != null || LocalAiService.state.value.running) return
        runCatching {
            check(RecordingService.state.value.meetingId == null) { "녹음을 저장한 뒤 실행해 주세요." }
            ContextCompat.startForegroundService(app, Intent(app, LocalAiService::class.java)
                .setAction(if (install) LocalAiService.INSTALL else LocalAiService.TRANSCRIBE).putExtra("meetingId", meeting?.id))
        }.onFailure { message = it.message ?: "로컬 작업을 시작하지 못했습니다." }
    }
    fun loadLocalProposal(id: String) = action {
        val saved = withContext(Dispatchers.IO) { LocalAiService.readProposal(app, id) }
        if (saved != null) proposal = AIProposal(saved.id, saved.revision, saved.utterances, source = "태블릿 로컬")
        else message = "보관된 로컬 전사 결과가 없습니다."
    }

    fun action(block: suspend () -> Unit) = viewModelScope.launch {
        try { block() } catch (e: CancellationException) { throw e }
        catch (e: Exception) { message = e.message ?: "처리하지 못했습니다. 다시 시도해 주세요." }
    }

    fun edit(id: String, block: (Meeting) -> Meeting) = action {
        withContext(Dispatchers.IO) { repository.update(id, edit = block) }
    }

    fun addExample() = action {
        val m = withContext(Dispatchers.IO) {
            repository.save(Meeting(title = "[예시] 다음 주 세미나 준비", status = "example", durationSeconds = 125.0,
                notes = "앱의 편집 기능을 확인하기 위한 가상 회의입니다.",
                utterances = listOf(
                    Utterance(1, "김민서", 0.0, 12.0, "다음 주 세미나는 목요일 오후 세 시로 정하면 좋겠습니다."),
                    Utterance(2, "이도윤", 15.0, 28.0, "발표 자료는 제가 수요일까지 공유하겠습니다. 장소는 확인이 필요합니다."),
                    Utterance(3, "김민서", 32.0, 45.0, "좋습니다. 제가 회의실을 확인하고 안내하겠습니다."),
                )))
        }
        selectedId = m.id
    }

    fun import(uri: Uri) = action {
        busy = "녹취 가져오는 중"
        try {
            val meeting = withContext(Dispatchers.IO) {
                val text = app.contentResolver.openInputStream(uri)?.use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val n = input.read(buffer); if (n < 0) break
                        require(output.size() + n <= 10 * 1024 * 1024) { "10MB 이하의 녹취 JSON을 선택해 주세요." }
                        output.write(buffer, 0, n)
                    }
                    output.toString("UTF-8")
                } ?: error("선택한 파일을 열 수 없습니다.")
                repository.import(text)
            }
            selectedId = meeting.id
            message = "녹취를 가져왔습니다. 원본 JSON도 함께 보관했습니다."
        } finally { busy = null }
    }

    fun export(uri: Uri, text: String) = action {
        withContext(Dispatchers.IO) {
            app.contentResolver.openOutputStream(uri, "wt")?.bufferedWriter(Charsets.UTF_8)?.use { it.write(text) }
                ?: error("내보낼 파일을 열 수 없습니다.")
        }
        message = "파일을 내보냈습니다."
    }

    fun requestAI(m: Meeting, speech: Boolean, approvedSettings: AISettings) {
        if (busy != null || LocalAiService.state.value.running) return
        if (speech && speechMode != SpeechMode.SERVER) { message = "서버 전사를 사용하려면 전사 방식을 서버로 선택해 주세요."; return }
        aiJob = viewModelScope.launch {
            try {
                busy = if (speech) "음성 전사 준비 중" else "회의록 작성 중"
                val client = AIClient(approvedSettings)
                proposal = if (speech) {
                    val audio = repository.audioFile(m) ?: error("전사할 녹음 파일이 없습니다.")
                    AIProposal(m.id, m.revision, utterances = client.transcribe(audio) { busy = it })
                } else AIProposal(m.id, m.revision, minutes = client.minutes(m))
            } catch (e: CancellationException) { message = "AI 요청을 취소했습니다." }
            catch (e: Exception) { message = e.message ?: "AI 요청을 처리하지 못했습니다." }
            finally { busy = null }
        }
    }

    fun cancelAI() {
        aiJob?.cancel()
        if (LocalAiService.state.value.running) app.startService(Intent(app, LocalAiService::class.java).setAction(LocalAiService.CANCEL))
    }
    fun applyProposal() = action {
        val p = proposal ?: return@action
        withContext(Dispatchers.IO) {
            repository.update(p.meetingId) {
                require(!it.deleted && it.revision == p.revision && RecordingService.state.value.meetingId != it.id) { "회의가 변경되었습니다. 현재 내용을 확인한 뒤 AI 요청을 다시 실행해 주세요." }
                it.copy(utterances = p.utterances ?: it.utterances, minutes = p.minutes ?: it.minutes)
            }
        }
        if (p.source == "태블릿 로컬") withContext(Dispatchers.IO) { LocalAiService.proposalFile(app, p.meetingId).delete() }
        proposal = null; message = "적용했습니다. 이전 내용은 변경 이력 파일로 보관했습니다."
    }
}
