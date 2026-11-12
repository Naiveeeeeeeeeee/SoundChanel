import AppKit
import Combine

struct AvoidanceTiming {
 var engaged=false
 var firstSound:TimeInterval?
 var lastSound:TimeInterval?
 mutating func sample(audible:Bool,now:TimeInterval,delay:TimeInterval)->Bool?{
  if audible{
   lastSound=now
   if firstSound==nil{firstSound=now}
   if !engaged,now-(firstSound ?? now)>=0.25{engaged=true;return true}
  }else{
   firstSound=nil
   if engaged,let lastSound,now-lastSound>=delay{engaged=false;return false}
  }
  return nil
 }
}

struct PausedPlayback {
 var bundle:String
 var pid:Int32
 var track:String
 var position:Double
}

// Uses the selected player's published scripting interface. Never launches a
// player and never sends a play command unless the same paused track remains.
final class PlaybackControl {
 static let supported:[String:String]=["com.apple.Music":"音乐","com.spotify.client":"Spotify"]
 let queue=DispatchQueue(label:"local.tonedesk.player-control",qos:.utility)
 static func quoted(_ value:String)->String{"\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""}
 func execute(_ source:String)->Result<String,Error>{
  let process=Process(),out=Pipe(),err=Pipe()
  process.executableURL=URL(fileURLWithPath:"/usr/bin/osascript");process.arguments=["-e",source]
  process.standardOutput=out;process.standardError=err
  do{
   try process.run()
   let timeout=DispatchWorkItem{if process.isRunning{process.terminate()}}
   DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+2,execute:timeout)
   process.waitUntilExit();timeout.cancel()
   let text=String(data:out.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
   let detail=String(data:err.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
   if process.terminationStatus != 0{throw NSError(domain:"Playback",code:Int(process.terminationStatus),userInfo:[NSLocalizedDescriptionKey:detail.contains("-1743") ? "请在系统设置的自动化权限中允许控制所选播放器。":"无法控制所选播放器，请检查播放状态与自动化权限。"])}
   return .success(text.trimmingCharacters(in:.whitespacesAndNewlines))
  }catch{return .failure(error)}
 }
 func pause(_ bundle:String,completion:@escaping(Result<PausedPlayback?,Error>)->Void){
  queue.async{
   guard Self.supported[bundle] != nil,let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else{DispatchQueue.main.async{completion(.success(nil))};return}
   let track=bundle=="com.apple.Music" ? "persistent ID of current track":"id of current track"
   let source="""
   with timeout of 2 seconds
    tell application id \(Self.quoted(bundle))
     if player state is not playing then return ""
     set trackID to \(track) as text
     pause
     return trackID & linefeed & (player position as text)
    end tell
   end timeout
   """
   let result=self.execute(source).map{value->PausedPlayback? in
    let parts=value.components(separatedBy:"\n")
    guard parts.count>=2,!parts[0].isEmpty,let position=Double(parts[1].replacingOccurrences(of:",",with:".")) else{return nil}
    return PausedPlayback(bundle:bundle,pid:app.processIdentifier,track:parts[0],position:position)
   }
   DispatchQueue.main.async{completion(result)}
  }
 }
 func resume(_ token:PausedPlayback,completion:(()->Void)?=nil){
  queue.async{
   defer{if let completion{DispatchQueue.main.async(execute:completion)}}
   guard Self.supported[token.bundle] != nil,NSRunningApplication.runningApplications(withBundleIdentifier:token.bundle).contains(where:{$0.processIdentifier==token.pid})else{return}
   let track=token.bundle=="com.apple.Music" ? "persistent ID of current track":"id of current track"
   let source="""
   with timeout of 2 seconds
    tell application id \(Self.quoted(token.bundle))
     if player state is paused and (\(track) as text) is \(Self.quoted(token.track)) then
      if (player position) > \(token.position-1) and (player position) < \(token.position+1) then play
     end if
    end tell
   end timeout
   """
   _ = self.execute(source)
  }
 }
}

final class MusicAvoidance:ObservableObject {
 @Published var enabled:Bool
 @Published var sourceID:String
 @Published var mode:String
 @Published var amount:Float
 @Published var delay:Double
 @Published var allSources:Bool
 @Published var triggers:Set<String>
 @Published var status="未启用"
 @Published var engaged=false
 let defaults:UserDefaults
 weak var mixer:Mixer?
 let monitorQueue=DispatchQueue(label:"local.tonedesk.activity",qos:.userInitiated)
 let player=PlaybackControl()
 lazy var pauseRequest:(String,@escaping(Result<PausedPlayback?,Error>)->Void)->Void = { [weak self] source,done in self?.player.pause(source,completion:done) }
 lazy var resumeRequest:(PausedPlayback,(() -> Void)?)->Void = { [weak self] token,done in self?.player.resume(token,completion:done) }
 var monitor:UnsafeMutableRawPointer?
 var monitorSignature=""
 var monitorGeneration=0
 var monitorStarting=false
 var monitorStartedAt=Date()
 var timer:Timer?
 var timing=AvoidanceTiming()
 var ownedChannel:Channel?
 var originalEnabled=false
 var pausedToken:PausedPlayback?
 var pausePending=false
 var playbackGeneration=0
 var foregroundObserver:NSObjectProtocol?
 var appliedSource=""
 var appliedMode=""
 var appliedAmount:Float=0
 var suppressResume=false
 var pendingShutdownCompletion:(()->Void)?
 init(mixer:Mixer,defaults:UserDefaults = .standard){
  self.mixer=mixer;self.defaults=defaults
  enabled=defaults.bool(forKey:"avoidance.enabled")
  sourceID=defaults.string(forKey:"avoidance.source") ?? "com.netease.163music"
  mode=defaults.string(forKey:"avoidance.mode") ?? "lower"
  amount=defaults.object(forKey:"avoidance.amount") as? Float ?? 0.2
  delay=defaults.object(forKey:"avoidance.delay") as? Double ?? 2
  allSources=defaults.object(forKey:"avoidance.all") as? Bool ?? true
  triggers=Set(defaults.stringArray(forKey:"avoidance.triggers") ?? ["com.google.Chrome","com.apple.FinalCut","local.source.quicklook","com.firecore.infuse","com.lemon.lv"])
  foregroundObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main){[weak self] note in
   guard let self,let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,app.bundleIdentifier==self.sourceID else{return}
   // Going back to the player counts as taking control: do not surprise the
   // user with a later automatic resume after they changed playback there.
   if self.pausedToken != nil || self.pausePending{self.suppressResume=true}
  }
 }
 func persist(){defaults.set(enabled,forKey:"avoidance.enabled");defaults.set(sourceID,forKey:"avoidance.source");defaults.set(mode,forKey:"avoidance.mode");defaults.set(amount,forKey:"avoidance.amount");defaults.set(delay,forKey:"avoidance.delay");defaults.set(allSources,forKey:"avoidance.all");defaults.set(Array(triggers).sorted(),forKey:"avoidance.triggers")}
 func settingsChanged(){
  amount=max(0,min(1,amount));delay=max(0.5,min(10,delay))
  if mode=="pause",PlaybackControl.supported[sourceID]==nil{mode="lower"}
  persist();configure(force:true)
 }
 func setEnabled(_ value:Bool){enabled=value;settingsChanged()}
 func setStatus(_ text:String){if status != text{status=text}}
 func stopMonitor(){
  monitorGeneration += 1;monitorSignature="";monitorStarting=false
  if let old=monitor{monitor=nil;monitorQueue.async{td_monitor_stop(old)}}
 }
 func configure(force:Bool=false){
  guard let mixer else{return}
  if force || sourceID != appliedSource || mode != appliedMode || amount != appliedAmount{
   restore();stopMonitor();timing=AvoidanceTiming();appliedSource=sourceID;appliedMode=mode;appliedAmount=amount
  }
  guard enabled,!mixer.paused else{restore();stopMonitor();timer?.invalidate();timer=nil;setStatus(enabled ? "音频处理已暂停":"未启用");return}
  let music=mixer.channels.first{$0.id==sourceID}
  guard let music,!music.processes.isEmpty else{if mode=="pause" && (pausedToken != nil || pausePending){return};restore();stopMonitor();setStatus("等待所选音乐来源播放");return}
  let ids:[UInt32]=allSources ? music.processes.sorted():mixer.channels.filter{triggers.contains($0.id) && $0.id != sourceID}.flatMap(\.processes).sorted()
  guard allSources || !ids.isEmpty else{restore();stopMonitor();setStatus("等待指定的触发音源");return}
  let signature=(allSources ? "all:":"selected:")+ids.map(String.init).joined(separator:",")
  if timer==nil{timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self]_ in self?.tick()};timer?.tolerance=0.025}
  guard signature != monitorSignature else{return}
  stopMonitor();monitorSignature=signature;monitorStarting=true;monitorStartedAt=Date();let generation=monitorGeneration;let global=allSources
  setStatus("正在准备音乐避让…")
  monitorQueue.async{[weak self] in
   var error=[CChar](repeating:0,count:512)
   let pointer=ids.withUnsafeBufferPointer{td_monitor_start($0.baseAddress,Int32(ids.count),global ? 1:0,&error,512)}
   let reason=String(cString:error)
   DispatchQueue.main.async{
    guard let self,self.enabled,self.monitorGeneration==generation else{if let pointer{DispatchQueue.global().async{td_monitor_stop(pointer)}};return}
    self.monitorStarting=false;self.monitor=pointer;self.monitorStartedAt=Date()
    self.setStatus(pointer == nil ? (reason.isEmpty ? "活动检测暂不可用":reason):"等待其他音源播放")
   }
  }
 }
 func tick(){
  guard enabled,let mixer,!mixer.paused,let monitor else{return}
  if td_monitor_frames(monitor)==0,Date().timeIntervalSince(monitorStartedAt)>8{setStatus("没有收到音频活动，请检查系统音频权限。")}
  if let change=timing.sample(audible:td_monitor_recent(monitor,160) != 0,now:Date.timeIntervalSinceReferenceDate,delay:delay){change ? engage():restore()}
 }
 func engage(){
  guard enabled,let mixer else{return}
  engaged=true
  if mode=="pause"{
   guard !pausePending,pausedToken==nil else{return};pausePending=true;suppressResume=false;let generation=playbackGeneration;let source=sourceID
   pauseRequest(source){[weak self] result in
    guard let self else{return};self.pausePending=false
    switch result{
    case .success(let token):
     guard self.playbackGeneration==generation,self.enabled,self.engaged,self.sourceID==source else{
      let finish=self.pendingShutdownCompletion;self.pendingShutdownCompletion=nil
      let retry={ [weak self] in
       finish?()
       guard let self,self.enabled,self.engaged,!self.suppressResume,self.mode=="pause" else{return}
       self.engage()
      }
      if let token,!self.suppressResume{self.resumeRequest(token,retry)}else{retry()};return
     }
     self.pausedToken=token;self.setStatus(token == nil ? "播放器当前没有播放音乐":"音乐已自动暂停")
    case .failure(let error):if self.playbackGeneration==generation{self.setStatus(error.localizedDescription)};let finish=self.pendingShutdownCompletion;self.pendingShutdownCompletion=nil;finish?()
    }
   }
  }else if let channel=mixer.channels.first(where:{$0.id==sourceID}){
   if ownedChannel == nil{
    ownedChannel=channel;originalEnabled=channel.enabled && channel.temporaryBaseGain==nil
    if !channel.enabled{channel.temporaryBaseGain=1;channel.enabled=true}
   }
   channel.avoidanceGain=amount;channel.apply();mixer.reconcile();setStatus("音乐已临时降低音量")
  }
 }
 func restore(completion:(()->Void)?=nil){
  engaged=false;timing=AvoidanceTiming();playbackGeneration += 1
  if let channel=ownedChannel{
   ownedChannel=nil;channel.avoidanceGain=1;channel.apply()
   if !originalEnabled{
    let generation=channel.generation
    DispatchQueue.main.asyncAfter(deadline:.now()+0.18){[weak self,weak channel] in
     guard let channel,channel.generation==generation,channel.temporaryBaseGain != nil,self?.ownedChannel !== channel else{return}
     channel.stop();channel.enabled=false;channel.temporaryBaseGain=nil;self?.mixer?.reconcile()
    }
   }else{channel.temporaryBaseGain=nil}
  }
  if let token=pausedToken{
   pausedToken=nil
   if !suppressResume{resumeRequest(token,completion)}else{completion?()}
  }else if pausePending,let completion{pendingShutdownCompletion=completion}else{completion?()}
  if enabled{setStatus("等待其他音源播放")}
 }
 func userEdited(_ channel:Channel){
  channel.temporaryBaseGain=nil
  guard ownedChannel === channel else{return}
  originalEnabled=true
 }
 func userDisabled(_ channel:Channel){if ownedChannel === channel{originalEnabled=true;enabled=false;persist();restore();stopMonitor();timer?.invalidate();timer=nil;setStatus("未启用")}}
 func shutdown(_ completion:@escaping()->Void){enabled=false;stopMonitor();timer?.invalidate();timer=nil;restore(completion:completion)}
 deinit{timer?.invalidate();if let foregroundObserver{NSWorkspace.shared.notificationCenter.removeObserver(foregroundObserver)}}
}
