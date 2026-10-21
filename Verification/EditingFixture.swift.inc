#if TABLELOG_VERIFICATION
extension AppModel {
    func loadEditingFixture() {
        phase = .completed
        statusMessage = "편집 화면 확인용 예시 회의"
        sessionTitle = "교육과정 기획 회의 · 예시"
        speakerIDs=[1,2];speakerNames=[1:"기획처장",2:"김교수"]
        segments=[
            TranscriptSegment(id:1,speaker:1,startTime:0,endTime:8,text:"이번 학기에는 실습 과목을 두 개 운영하겠습니다."),
            TranscriptSegment(id:2,speaker:1,startTime:8,endTime:16,text:"실습 예산은 삼천만원으로 검토하겠습니다."),
            TranscriptSegment(id:3,speaker:2,startTime:16,endTime:24,text:"학생 의견을 다음 회의에서 공유하겠습니다.")]
        liveText=segments.map(\.text).joined(separator:" ");audioSeconds=24
        syncMeetingMinutes(force:true)
    }
}
#endif
