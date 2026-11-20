import Foundation
import Darwin
@main struct Check {
 static func main() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("TableLog-NoRunLoop-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let input=root.appendingPathComponent("input"),output=root.appendingPathComponent("output"),error=root.appendingPathComponent("error")
  for file in [input,output,error] { try Data().write(to:file) }
  let done=DispatchSemaphore(value:0)
  DispatchQueue.global().async {
   do {
    let code=try ManagedChildProcess().run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","printf finished; exit 4"],environment:[:],directory:root,input:input,output:output,diagnostics:error,timeout:1)
    guard code==4 else { fatalError("exit code") }
    done.signal()
   } catch { fatalError(error.localizedDescription) }
  }
  // Deliberately keep the main run loop stopped while the child launches and exits.
  guard done.wait(timeout:.now()+2) == .success else { fatalError("run-loop-dependent exit") }
  guard try String(contentsOf:output,encoding:.utf8)=="finished" else { fatalError("output") }
  print("PASS: child exit was reaped while main run loop stayed blocked")
 }
}
