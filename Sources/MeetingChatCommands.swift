import Foundation

/// Clear local commands remain usable while an AI account is paused.
enum MeetingChatCommands {
    static let help="회의 제목·목적·장소·예정 일시, 전사 맥락·교정 용어, 발언·화자, 회의록, 여러 회의자료를 수정할 수 있어요. 자료 추가와 전사·회의록의 일괄 치환도 지원해요. 예: ‘회의 제목을 운영협의회로 바꿔 줘’, ‘장소는 부산, 예정 일시는 오늘 10~14시로 설정해 줘’. 수정안을 확인하고 ‘변경 적용’을 누르면 저장돼요. 적용한 변경은 ‘되돌리기’로 복원할 수 있어요."
    static func plan(for request:String,snapshot:EditingSnapshot) -> EditingPlan? {
        let text=request.trimmingCharacters(in:.whitespacesAndNewlines)
        if ["도움말","사용법","가능한 작업","뭘 할 수 있어?","무엇을 할 수 있어?"].contains(text) {
            return EditingPlan(answer:help,changes:[])
        }
        let patterns=[
            #"^(?:(?:이번|현재)\s*)?(?:회의\s*(?:제목|명)|제목|타이틀)(?:을|를)?\s+(.+?)(?:으로|로)\s*(?:바꿔\s*(?:줘|주세요)|변경해\s*(?:줘|주세요)|수정해\s*(?:줘|주세요)|설정해\s*(?:줘|주세요)|정해\s*(?:줘|주세요))(?:[.!]|요)?$"#,
            #"^회의\s*(?:제목|명)\s*[:：]\s*([^\r\n]+)$"#
        ]
        guard let document=snapshot.documents.first(where:{$0.id=="meeting.title"}) else { return nil }
        for pattern in patterns {
            guard let regex=try? NSRegularExpression(pattern:pattern),
                  let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
                  let range=Range(match.range(at:1),in:text) else { continue }
            var title=String(text[range]).trimmingCharacters(in:.whitespacesAndNewlines)
            let quotes:[Character:Character]=["'":"'","\"":"\"","‘":"’","“":"”","`":"`"]
            if title.count>=2,let first=title.first,quotes[first]==title.last { title=String(title.dropFirst().dropLast()) }
            title=title.split(whereSeparator:\.isWhitespace).joined(separator:" ")
            guard !title.isEmpty,title.count<=160 else { return nil }
            if title==document.text { return EditingPlan(answer:"현재 회의 제목이 ‘\(title)’예요.",changes:[]) }
            return EditingPlan(answer:"회의 제목을 ‘\(title)’로 바꿀게요. 변경 적용을 누르면 화면·저장 기록과 회의록 제목에 반영돼요.",
                changes:[EditingChange(targetID:document.id,before:document.text,after:title,speaker:-1)])
        }
        return nil
    }
}
