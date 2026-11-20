package work.yunju.tablelog

import android.app.Application
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import work.yunju.tablelog.data.MeetingRepository

class TableLogApplication : Application() {
    lateinit var repository: MeetingRepository
        private set
    val ready = MutableStateFlow(false)
    override fun onCreate() {
        super.onCreate()
        repository = MeetingRepository(this)
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            repository.load()
            ready.value = true
        }
    }
}
