import AppKit
import SwiftUI
import Foundation
import Darwin

/// A real ContentView with synthetic, local-only recording updates. All stores are temporary.
@main struct PerformanceApp {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let headless = CommandLine.arguments.contains("--headless")
        let stress = CommandLine.arguments.contains("--layout-stress")
        let speakerUI = CommandLine.arguments.contains("--speaker-ui")
        app.setActivationPolicy(headless ? .prohibited : .regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TableLogPerformance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "local.TableLog.Performance." + UUID().uuidString)!
        defaults.set(false, forKey: "assistant.enabled")
        defaults.set(false, forKey: "minutes.automatic")
        defaults.set(false, forKey: "minutes.onFinish")
        var settings = CodexCorrectionSettings(); settings.mode = .off
        defaults.set(try JSONEncoder().encode(settings), forKey: "codexCorrection.v1")
        let model = AppModel(materials: MeetingMaterials(root: root.appendingPathComponent("Materials")),
            meeting: MeetingWorkspace(directory: root.appendingPathComponent("Minutes"), defaults: defaults),
            assistant: MeetingAssistant(directory: root.appendingPathComponent("Assistant"), defaults: defaults),
            loadEngine: false, voice: VoiceIdentity(root: root.appendingPathComponent("Voice")),
            history: MeetingHistoryStore(transcripts: root.appendingPathComponent("Transcripts"), minutes: root.appendingPathComponent("Minutes")),
            transcriptDirectory: root.appendingPathComponent("Transcripts"), startBackgroundServices: false, preferences: defaults)
        if speakerUI { model.loadVoiceNameFixture() }
        model.phase = .recording
        model.statusMessage = "성능 측정용 가상 회의 · 로컬 샘플 재생"
        func segment(_ index: Int) -> TranscriptSegment {
            let text = "안건 \(index)번을 검토하겠습니다. " + String(repeating: "담당 부서에서 추진 일정과 예산을 확인하고 다음 회의에 결과를 공유하겠습니다. ", count: 5)
            return TranscriptSegment(id: index, speaker: 1 + (index / 8) % 4,
                startTime: Double(index * 10), endTime: Double(index * 10 + 10), text: text)
        }
        model.segments = (0..<1_000).map(segment)
        model.audioSeconds = 10_000
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 850),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TableLog 성능 샘플"
        let hosting = NSHostingView(rootView: ContentView(model: model))
        window.contentView = hosting
        // Exercise the actual editor and transcript together without opening the user's meeting.
        let editor = NSHostingView(rootView: SpeakerNamesEditor(model: model, preferredSpeaker: 1, dismiss: {}))
        let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        if speakerUI { editorWindow.contentView = editor }
        if !headless { window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true) }
        var renderCount = 0
        let runner = PerformanceRun(model: model, headless: headless, stress: stress, speakerUI: speakerUI, render: {
            renderCount += 1
            if speakerUI {
                switch renderCount % 4 {
                case 0: model.resetVoiceNamesForLayoutFixture()
                case 1: precondition(model.confirmVoiceName(1, expectedName: "김하늘"))
                case 2: precondition(model.confirmVoiceName(2, expectedName: "이서준"))
                default: model.confirmEnteredSpeakerName("이름을 직접 확인한 참석자", for: 1)
                }
                editor.needsLayout = true
                editor.layoutSubtreeIfNeeded()
                let size = editor.fittingSize
                precondition(abs(size.width - 480) < 1 && abs(size.height - 560) < 1,
                    "Confirming a voice name changed the editor viewport")
            }
            if stress, renderCount % 7 == 0 {
                window.setContentSize(NSSize(width: renderCount % 14 == 0 ? 1600 : 1240,
                                             height: renderCount % 14 == 0 ? 960 : 720))
            }
            guard headless else { return }
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
        }, capture: {
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("performance-preview.png"))
                }
            }
        }, makeSegment: segment)
        runner.start()
        withExtendedLifetime((window, editorWindow, runner)) { app.run() }
    }
}

@MainActor final class PerformanceRun {
    let model: AppModel
    let headless: Bool
    let stress: Bool
    let speakerUI: Bool
    let render: () -> Void
    let capture: () -> Void
    let makeSegment: (Int) -> TranscriptSegment
    var timers: [Timer] = []
    var began = 0.0, cpuBegan = 0.0, lastBeat = 0.0
    var gaps: [Double] = [], updates = 0, peakRSS: UInt64 = 0
    var layoutTimes: [Double] = []
    var measuring = false
    var watchdog: DispatchWorkItem?
    init(model: AppModel, headless: Bool, stress: Bool, speakerUI: Bool, render: @escaping () -> Void, capture: @escaping () -> Void, makeSegment: @escaping (Int) -> TranscriptSegment) {
        self.model = model; self.headless = headless; self.stress = stress; self.speakerUI = speakerUI; self.render = render; self.capture = capture; self.makeSegment = makeSegment
    }
    func start() {
        // A separate queue catches a stalled main run loop during the synthetic run.
        let deadline = DispatchWorkItem {
            fputs("FAIL: layout test exceeded the main-loop deadline\n", stderr)
            exit(2)
        }
        watchdog = deadline
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 65, execute: deadline)
        every(0.125) { [self] in
            model.inputLevel = Double.random(in: 0...1)
            model.audioSeconds += 0.125
        }
        every(stress ? 0.05 : 0.5) { [self] in
            let start = ProcessInfo.processInfo.systemUptime
            model.segments.append(makeSegment(model.segments.count))
            if stress, model.segments.count % 3 == 0 {
                let last = model.segments.last!
                model.segments[model.segments.count - 1] = TranscriptSegment(id: last.id, speaker: last.speaker,
                    startTime: last.startTime, endTime: last.endTime,
                    text: last.text + String(repeating: "추가 논의 내용. ", count: model.segments.count % 30))
            }
            model.liveText = model.segments.last!.text
            render()
            if measuring { updates += 1; layoutTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
        }
        every(0.016) { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            if measuring { gaps.append((now - lastBeat) * 1_000) }
            lastBeat = now
        }
        every(0.25) { [self] in peakRSS = max(peakRSS, residentBytes()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
            began = ProcessInfo.processInfo.systemUptime; cpuBegan = cpuSeconds()
            peakRSS = residentBytes(); measuring = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (stress ? 30 : 20)) { [self] in finish() }
        }
    }
    func every(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(timer, forMode: .common); timers.append(timer)
    }
    func finish() {
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let cpu = cpuSeconds() - cpuBegan
        timers.forEach { $0.invalidate() }
        watchdog?.cancel()
        let sorted = gaps.sorted()
        let layouts = layoutTimes.sorted()
        let report: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "sample",
            "duration_seconds": elapsed, "cpu_seconds": cpu, "cpu_percent_one_core": cpu / elapsed * 100,
            "peak_rss_mib": Double(peakRSS) / 1_048_576, "final_rss_mib": Double(residentBytes()) / 1_048_576,
            "heartbeat_p95_ms": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            "heartbeat_max_ms": sorted.last ?? 0, "heartbeat_over_100ms": gaps.filter { $0 > 100 }.count,
            "update_layout_p95_ms": layouts.isEmpty ? 0 : layouts[min(layouts.count - 1, Int(Double(layouts.count) * 0.95))],
            "transcript_updates": updates, "segments": model.segments.count,
            "rendering": headless ? "offscreen NSHostingView layout; bitmap capture only after measurement" : "interactive window",
            "layout_stress": stress,
            "speaker_ui": speakerUI,
            "speaker_name_actions": speakerUI ? updates : 0,
            "scenario": "1000 synthetic segments, \(stress ? 20 : 2) transcript updates/s, 8 meter updates/s; 5s warmup + \(stress ? 30 : 20)s measurement; ASR and AI disabled"
        ]
        let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("performance-result.json")
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { fputs("Performance report: \(error)\n", stderr) }
        if headless { capture() }
        model.phase = .completed
        model.statusMessage = "측정 완료 · CPU \(Int(cpu / elapsed * 100))% · 메모리 \(Int(Double(peakRSS) / 1_048_576))MB"
        if headless { exit((stress || speakerUI) && ((sorted.last ?? 0) > 1_000 || updates < (stress ? 100 : 20)) ? 1 : 0) }
    }
    func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
