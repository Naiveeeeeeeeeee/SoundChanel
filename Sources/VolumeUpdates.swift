import Foundation

struct DeviceVolumeKey: Hashable {
 let device: UInt32
 let input: Bool
}

// Latest value wins for each device. Hardware drivers may block; never call
// them on the UI thread or build an unbounded queue of stale slider positions.
final class HardwareVolumeWriter {
 private let lock = NSLock()
 private let queue = DispatchQueue(label: "local.tonedesk.hardware-volume", qos: .userInitiated)
 private var pending: [DeviceVolumeKey: Float] = [:]
 private var scheduled = false
 private var completions: [() -> Void] = []
 var write: (DeviceVolumeKey, Float) -> Int32 = { td_volume($0.device, $0.input ? 1 : 0, $1) }
 var onError: ((Int32) -> Void)?
 var onIdle: (() -> Void)?

 var isIdle:Bool{lock.lock();defer{lock.unlock()};return !scheduled}

 func submit(_ key: DeviceVolumeKey, _ value: Float) {
  lock.lock()
  pending[key] = max(0, min(1, value))
  let start = !scheduled
  scheduled = true
  lock.unlock()
  if start { queue.asyncAfter(deadline: .now() + 0.008) { self.drain() } }
 }
 func whenIdle(_ completion: @escaping () -> Void) {
  lock.lock()
  if scheduled { completions.append(completion); lock.unlock() }
  else { lock.unlock(); DispatchQueue.main.async(execute: completion) }
 }
 private func drain() {
  lock.lock(); let batch = pending; pending.removeAll(); lock.unlock()
  for (key, value) in batch {
   let code = write(key, value)
   if code != 0 { DispatchQueue.main.async { self.onError?(code) } }
  }
  lock.lock()
  if !pending.isEmpty {
   lock.unlock(); queue.asyncAfter(deadline: .now() + 1.0 / 60) { self.drain() }
  } else {
   scheduled = false
   let callbacks = completions; completions.removeAll()
   // Queue idle notification before a later submit can queue its completion.
   DispatchQueue.main.async { self.onIdle?(); callbacks.forEach { $0() } }
   lock.unlock()
  }
 }
}

// No hardware writes: a deliberately slow driver exercises queue coalescing
// and UI responsiveness without changing the user's playback or volume.
@MainActor func volumeResponsivenessTest() async -> Int32 {
 let writer=HardwareVolumeWriter()
 let lock=NSLock()
 var writes:[(DeviceVolumeKey,Float)]=[]
 writer.write={key,value in
  Thread.sleep(forTimeInterval:0.035)
  lock.lock();writes.append((key,value));lock.unlock()
  return 0
 }
 let a=DeviceVolumeKey(device:1,input:false),b=DeviceVolumeKey(device:2,input:true)
 var ticks=0
 let heartbeat=DispatchSource.makeTimerSource(queue:.main)
 heartbeat.schedule(deadline:.now(),repeating:0.005)
 heartbeat.setEventHandler{ticks += 1};heartbeat.resume()
 defer{heartbeat.cancel()}
 let start=Date()
 for i in 0..<500 {writer.submit(a,Float(i)/500)}
 writer.submit(b,0.2);writer.submit(a,0)
 let enqueue=Date().timeIntervalSince(start)
 await withCheckedContinuation{(continuation:CheckedContinuation<Void,Never>) in writer.whenIdle{continuation.resume()}}
 let output=lock.withLock{writes}
 guard output.last(where:{$0.0==a})?.1==0,output.last(where:{$0.0==b})?.1==0.2,
       output.count<20,ticks>=5,enqueue<0.05 else{
  print("FAIL coalescing/responsiveness",output.count,ticks,enqueue);return 1
 }
 let mixer=Mixer(testing:true)
 mixer.beginInteraction()
 for _ in 0..<500{mixer.refresh()}
 guard !mixer.refreshInFlight,mixer.snapshotCount==0 else{print("FAIL refresh during drag");return 2}
 mixer.interactionDepth=0
 let channel=Channel(id:"test.performance."+UUID().uuidString,name:"性能测试")
 defer{channel.saveWork?.cancel();UserDefaults.standard.removeObject(forKey:"channel."+channel.id)}
 for i in 0..<200{channel.config.volume=Float(i)/100;channel.save()}
 channel.config.volume=0.37;channel.flushSave()
 guard let data=UserDefaults.standard.data(forKey:"channel."+channel.id),
       let saved=try? JSONDecoder().decode(Settings.self,from:data),saved.volume==0.37 else{
  print("FAIL final configuration persistence");return 3
 }
 print("PASS: 502 slider submissions -> \(output.count) hardware writes; final 0% and independent input 20% retained; \(ticks) main-thread heartbeats during slow driver.")
 print("PASS: no device/process scans during 500 drag refresh requests; final configuration flushed correctly.")
 return 0
}

@MainActor func auditStateTest() async -> Int32 {
 let mixer=Mixer(testing:true)
 mixer.global.enabled=false
 let device=Device(id:9,uid:"test-output",name:"测试设备",inputs:2,outputs:2,volume:0.9,inputVolume:0.8,canVolume:true,canInputVolume:true,muted:false,inputMuted:false,canMute:true,canInputMute:true,rate:48000)
 mixer.devices=[device];mixer.output=9;mixer.input=9;mixer.effects=9
 let lock=NSLock(),gate=DispatchSemaphore(value:0)
 var started=false
 var writes:[(DeviceVolumeKey,Float)]=[]
 mixer.volumeWriter.onIdle={mixer.hardwareWriteActive=false}
 mixer.volumeWriter.write={key,value in
  let first=lock.withLock{()->Bool in if !started{started=true;return true};return false}
  if first{_ = gate.wait(timeout:.now()+3)}
  lock.withLock{writes.append((key,value))}
  return 0
 }
 mixer.setDeviceVolume(9,input:false,value:0.2)
 for _ in 0..<100{if lock.withLock({started}){break};try? await Task.sleep(nanoseconds:1_000_000)}
 guard lock.withLock({started}) else{gate.signal();print("FAIL slow writer did not start");return 1}
 mixer.setDeviceVolume(9,input:false,value:0.35)
 mixer.setDeviceVolume(9,input:true,value:0.4)
 let scene=mixer.captureScene(name:"保存时仍在写入")
 guard scene.volume==0.35,scene.inputVolume==0.4,scene.output=="test-output" else{
  gate.signal();print("FAIL saved stale hardware snapshot");return 2
 }
 // Loading a later preset must win over both a running old write and pending
 // slider values. This is the exact writer entry used by restoreScene.
 mixer.setDeviceVolume(9,input:false,value:0.7)
 gate.signal()
 await withCheckedContinuation{(continuation:CheckedContinuation<Void,Never>) in mixer.volumeWriter.whenIdle{continuation.resume()}}
 let values=lock.withLock{writes}
 guard values.last(where:{$0.0==DeviceVolumeKey(device:9,input:false)})?.1==0.7,
       values.last(where:{$0.0==DeviceVolumeKey(device:9,input:true)})?.1==0.4 else{
  print("FAIL preset lost to old queued slider value");return 3
 }
 mixer.beginInteraction();mixer.beginInteraction();mixer.cancelInteractions()
 guard mixer.interactionDepth==0 else{print("FAIL canceled drag blocks later refresh");return 4}
 let failure=HardwareVolumeWriter()
 var reported:Int32=0
 failure.write={_,_ in -9};failure.onError={reported=$0}
 failure.submit(DeviceVolumeKey(device:99,input:false),0.5)
 await withCheckedContinuation{(continuation:CheckedContinuation<Void,Never>) in failure.whenIdle{continuation.resume()}}
 guard reported == -9,failure.isIdle else{print("FAIL failed driver completion");return 5}
 print("PASS: save captures pending output/input values; newer preset wins over in-flight slider; canceled tracking resets; failed driver reports error and completes.")
 return 0
}
