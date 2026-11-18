import AppKit
import SwiftUI
import Foundation
import Darwin

/// A real ContentView with synthetic, local-only recording updates. All stores are temporary.
@main struct PerformanceApp {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let headless = CommandLine.arguments.contains("--headless")
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
        if !headless { window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true) }
        let runner = PerformanceRun(model: model, headless: headless, render: {
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
        withExtendedLifetime((window, runner)) { app.run() }
    }
}

@MainActor final class PerformanceRun {
    let model: AppModel
    let headless: Bool
    let render: () -> Void
    let capture: () -> Void
    let makeSegment: (Int) -> TranscriptSegment
    var timers: [Timer] = []
    var began = 0.0, cpuBegan = 0.0, lastBeat = 0.0
    var gaps: [Double] = [], updates = 0, peakRSS: UInt64 = 0
    var layoutTimes: [Double] = []
    var measuring = false
    init(model: AppModel, headless: Bool, render: @escaping () -> Void, capture: @escaping () -> Void, makeSegment: @escaping (Int) -> TranscriptSegment) {
        self.model = model; self.headless = headless; self.render = render; self.capture = capture; self.makeSegment = makeSegment
    }
    func start() {
        every(0.125) { [self] in
            model.inputLevel = Double.random(in: 0...1)
            model.audioSeconds += 0.125
        }
        every(0.5) { [self] in
            let start = ProcessInfo.processInfo.systemUptime
            model.segments.append(makeSegment(model.segments.count))
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in finish() }
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
            "scenario": "1000 synthetic segments, 2 transcript updates/s, 8 meter updates/s; 5s warmup + 20s measurement; ASR and AI disabled"
        ]
        let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("performance-result.json")
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { fputs("Performance report: \(error)\n", stderr) }
        if headless { capture() }
        model.phase = .completed
        model.statusMessage = "측정 완료 · CPU \(Int(cpu / elapsed * 100))% · 메모리 \(Int(Double(peakRSS) / 1_048_576))MB"
        if headless { exit(0) }
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
