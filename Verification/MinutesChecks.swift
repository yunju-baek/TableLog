import Foundation

actor MinutesCallLog {
    var stages: [String] = []
    func add(_ stage: String) { stages.append(stage) }
}

@main struct MinutesChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--generate-record" {
            let record = try JSONDecoder().decode(MeetingWorkRecord.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let folder = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let generator = MinutesGenerator()
            let facts = try await generator.generate(record.input,provider:.codex,settings:record.settings) { part,total in
                print("Minutes generation \(part)/\(total)");fflush(stdout)
            }
            let text = try MeetingMinutesRenderer.render(record.snapshot(facts:facts),template:record.template)
            try text.write(to:folder.appendingPathComponent("minutes.md"),atomically:true,encoding:.utf8)
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(facts).write(to:folder.appendingPathComponent("facts.json"),options:.atomic)
            print("Generated: \(text.count) characters; \(facts.discussions.count) topics; \(facts.actions.count) actions")
            return
        }
        var passed=0
        func check(_ value:Bool,_ label:String) { precondition(value,label);passed+=1;print("PASS: "+label) }
        let speech = [MeetingUtterance(id:1,speaker:1,start:42,end:51,text:"원본 전사 고유 표식: 예산 3천만 원은 검토안입니다."),
                      MeetingUtterance(id:2,speaker:2,start:65,end:78,text:"11월 3일 10:00에 검토 회의를 열겠습니다.")]
        var facts=MeetingMinutesFacts()
        facts.summary=[.init(text:"예산 3천만 원의 집행 조건을 검토했다.",evidenceIDs:[1])]
        facts.decisions=[.init(text:"11월 3일 10:00에 검토 회의를 개최한다.",evidenceIDs:[2])]
        facts.actions=[.init(text:"자료 A | B 검토",assignee:nil,deadline:nil,evidenceIDs:[1,2])]
        facts.discussions=[.init(title:"사업 예산 검토",points:[.init(text:"예산 3천만 원을 검토안으로 제시했다. 집행 조건은 후속 협의에서 정한다.",evidenceIDs:[1])])]
        let person=MeetingPerson(id:"p1",name:"김담당")
        func snapshot(_ facts:MeetingMinutesFacts) -> MeetingMinutesSnapshot {
            .init(sessionID:UUID(),revision:1,date:"2026-10-21 16:35:59 GMT+9",purpose:"",confirmedParticipants:[person,person],speakerBindings:[1:person],utterances:speech,facts:facts,referenceAppendix:"\n# 도우미 기록\n[00:42] 민감한 부록",title:"사업 추진 회의")
        }
        let legacy=MeetingTemplate(name:"기존 서식",markdown:"# 핵심 요약\n{{summary}}\n# 결정 사항\n| 결정 | 근거 시각 |\n{{decisions}}\n전사문:\n{{transcript}}",similarTopics:["예산"],participantCandidates:[person])
        let text=try MeetingMinutesRenderer.render(snapshot(facts),template:legacy)
        check(text.hasPrefix("# 사업 추진 회의"),"meeting title included")
        check(text.contains("- 일자: 2026-10-21") && !text.contains("16:35:59"),"meeting date uses a date-only format")
        check(!text.contains("전사문") && !text.contains("원본 전사 고유 표식"),"legacy templates omit source transcript")
        check(!text.contains("00:42") && !text.contains("근거 시각"),"evidence remains internal")
        check(!text.contains("도우미 기록") && !text.contains("민감한 부록"),"raw assistant appendix omitted")
        check(text.contains("11월 3일 10:00"),"actual business schedule preserved")
        check(text.contains("자료 A \\| B 검토 | 확인 필요 | 확인 필요"),"action cells escape pipes and preserve uncertainty")
        check(!text.contains("김담당, 김담당"),"participant names deduplicated")
        check(legacy.minutesOnly.id==legacy.id && legacy.minutesOnly.similarTopics==legacy.similarTopics,"legacy template identity and topics preserved")
        check(legacy.markdown.contains("{{transcript}}"),"source template remains intact")
        var invalid=facts;invalid.summary=[.init(text:"근거 오류",evidenceIDs:[999])]
        do { _=try MeetingMinutesRenderer.render(snapshot(invalid),template:legacy);preconditionFailure("invalid evidence accepted") }
        catch { passed+=1;print("PASS: invalid evidence rejected") }
        let input=MinutesGenerationInput(segments:speech,purpose:"",relatedTopics:[],speakerNames:["1":"김담당"],title:"사업 추진 회의")
        let payload=try MinutesGenerator.payload(input,segments:speech)
        check(!payload.contains("\"start\"") && !payload.contains("\"end\""),"audio clocks excluded from AI input")
        let log=MinutesCallLog()
        let responder: MinutesGenerator.Response = { prompt,payload,_,ids in
            await log.add(prompt == MinutesGenerator.synthesisInstruction ? "synthesis" : prompt == MinutesGenerator.extractionInstruction ? "extract" : "whole")
            var value=MeetingMinutesFacts()
            value.summary=[.init(text:prompt == MinutesGenerator.synthesisInstruction ? "전체 회의 종합" : "검증된 논의",evidenceIDs:[ids.first!])]
            return value
        }
        let generator=MinutesGenerator(responder:responder)
        _=try await generator.generate(input,provider:.codex,settings:CodexCorrectionSettings()) { _,_ in }
        check(await log.stages == ["whole"],"ordinary meetings use full-context synthesis")
        let long=(1...12).map { MeetingUtterance(id:$0,speaker:1,start:Double($0),end:Double($0+1),text:String(repeating:"가",count:9000)) }
        let longInput=MinutesGenerationInput(segments:long,purpose:"",relatedTopics:[],speakerNames:[:])
        let result=try await generator.generate(longInput,provider:.codex,settings:CodexCorrectionSettings()) { _,_ in }
        let stages=await log.stages
        check(stages.filter{$0=="extract"}.count>1 && stages.last=="synthesis","long meetings finish with semantic synthesis")
        check(result.summary.count==1 && result.summary[0].text=="전체 회의 종합","chunk summaries are replaced by coherent final output")
        let fail=MinutesGenerator(responder:{ _,_,_,_ in var value=MeetingMinutesFacts();value.summary=[.init(text:"오류",evidenceIDs:[999])];return value })
        do { _=try await fail.generate(input,provider:.codex,settings:CodexCorrectionSettings()) { _,_ in };preconditionFailure("invalid model evidence accepted") }
        catch { passed+=1;print("PASS: invalid model evidence rejected") }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TableLogMinutesChecks-"+UUID().uuidString)
        let store=MeetingFileStore(directory:folder)
        let output=try await store.save(snapshot(facts),template:legacy)
        check(try String(contentsOf:output,encoding:.utf8)==text,"saved Markdown matches the clean renderer")
        print("RESULT: \(passed) minutes checks passed")
    }
}
