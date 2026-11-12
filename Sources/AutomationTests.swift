import Foundation
import AppKit
import SwiftUI

@MainActor func automationTests() async -> Int32 {
 var failures=0
 func check(_ ok:Bool,_ name:String){print("\(ok ? "PASS":"FAIL") \(name)");if !ok{failures += 1}}
 func wait(_ seconds:Double) async{try? await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
 var policy=OutputPriorityPolicy()
 func choose(_ connected:Set<String>,order:[String]=["headphones","speaker"],current:String="speaker",enabled:Bool=true)->String?{policy.choose(connected:connected,order:order,current:current,enabled:enabled)}
 check(choose(["headphones","speaker"])=="headphones","priority enabled: select highest connected device")
 check(choose(["headphones","speaker"],current:"headphones")==nil,"stable polling does not repeat device writes")
 policy.selectedManually("speaker")
 check(choose(["headphones","speaker"])==nil,"manual selection remains until device/order change")
 check(choose(["speaker"])==nil,"disconnect: retain available current output")
 check(choose(["headphones","speaker"])=="headphones","reconnection restores preferred device")
 _ = choose(["headphones","speaker"],current:"headphones")
 check(choose(["headphones","speaker"])==nil,"external system selection respected")
 check(choose(["headphones","speaker"],order:["speaker","headphones"],current:"headphones")=="speaker","reordering applies immediately")
 check(choose(["headphones","speaker"],enabled:false)==nil,"disabled priority never switches")
 let suite="local.tonedesk.test."+UUID().uuidString
 let defaults=UserDefaults(suiteName:suite)!
 defer{defaults.removePersistentDomain(forName:suite)}
 let priority=DevicePriority(defaults:defaults)
 priority.order=[PreferredDevice(id:"offline",name:"离线耳机"),PreferredDevice(id:"speaker",name:"扬声器")];priority.move("speaker",-1);priority.setEnabled(true)
 let loaded=DevicePriority(defaults:defaults)
 check(loaded.enabled && loaded.order.map(\.id)==["speaker","offline"],"priority order/offline preference persisted")
 var timing=AvoidanceTiming()
 check(timing.sample(audible:true,now:0,delay:2)==nil && timing.sample(audible:false,now:0.1,delay:2)==nil,"brief notification does not interrupt music")
 _ = timing.sample(audible:true,now:1,delay:2)
 check(timing.sample(audible:true,now:1.3,delay:2)==true,"sustained sound engages avoidance")
 check(timing.sample(audible:false,now:2,delay:2)==nil && timing.sample(audible:false,now:3.4,delay:2)==false,"restore only after configured quiet delay")
 let mixer=Mixer(testing:true),c=Channel(id:"test.avoidance."+UUID().uuidString,name:"音乐测试")
 mixer.channels=[c];mixer.global.enabled=false;c.enabled=false;c.config.volume=0.37;c.config.mute=true;c.config.eq=true;c.config.balance=0.8;c.config.outputUID="offline"
 defer{c.saveWork?.cancel();c.stop();UserDefaults.standard.removeObject(forKey:"channel."+c.id);UserDefaults.standard.removeObject(forKey:"enabled."+c.id)}
 let avoidance=MusicAvoidance(mixer:mixer,defaults:defaults)
 avoidance.enabled=true;avoidance.sourceID=c.id;avoidance.mode="lower";avoidance.amount=0.2
 avoidance.engage()
 check(c.enabled && c.temporaryBaseGain==1 && abs(c.effectiveGain-0.2)<0.0001 && c.config.volume==0.37,"temporary duck on unmanaged source leaves slider/config unchanged")
 check(!c.processingSettings.mute && !c.processingSettings.eq && c.processingSettings.balance==0 && c.effectsBypassed && mixer.target(c)==mixer.output,"temporary capture ignores inactive mute/effects/device settings")
 check(mixer.captureScene(name:"test").channels.first{$0.id==c.id}?.enabled==false,"saving a scene does not persist temporary capture ownership")
 avoidance.restore();await wait(0.25)
 check(!c.enabled && c.temporaryBaseGain==nil && c.avoidanceGain==1 && !avoidance.timing.engaged,"release returns unmanaged source to original playback")
 c.enabled=true;avoidance.engage();avoidance.restore();await wait(0.25)
 check(c.enabled && abs(c.effectiveGain-td_volume_gain(0.37))<0.0001,"managed source retains its original volume and capture")
 c.enabled=false;avoidance.engage();avoidance.restore();avoidance.engage();await wait(0.25)
 check(c.enabled && c.avoidanceGain==0.2,"renewed sound cannot be stopped by a stale release callback")
 avoidance.restore();await wait(0.25)
 avoidance.engage();avoidance.restore();avoidance.userEdited(c);c.config.volume=0.61;await wait(0.25)
 check(c.enabled && c.temporaryBaseGain==nil,"manual editing cancels pending temporary capture release")
 avoidance.engage();avoidance.userDisabled(c)
 check(!avoidance.enabled && c.avoidanceGain==1,"manual release disables avoidance instead of re-enabling capture")
 mixer.musicAvoidance=avoidance;mixer.isTesting=false
 avoidance.enabled=true;c.enabled=false;avoidance.engage();mixer.reset(c);avoidance.restore();await wait(0.25)
 check(c.enabled && c.temporaryBaseGain==nil,"manual reset keeps ownership after ducking ends")
 c.enabled=false;avoidance.engage();mixer.timedMute(c,30);avoidance.restore();await wait(0.25)
 check(c.enabled && c.config.mute && c.processingSettings.mute,"timed mute takes effect during temporary avoidance")
 c.enabled=false;c.config.mute=false;avoidance.engage();mixer.loadPlugin(c,nil);avoidance.restore();await wait(0.25)
 check(c.enabled && c.temporaryBaseGain==nil,"manual plugin selection keeps ownership after ducking ends")
 mixer.isTesting=true
 // Simulate asynchronous player replies without touching a user's music player.
 avoidance.enabled=true;avoidance.mode="pause";avoidance.sourceID="com.apple.Music"
 var pending:((Result<PausedPlayback?,Error>)->Void)?
 var resumed=0
 avoidance.pauseRequest={_,done in pending=done}
 avoidance.resumeRequest={_,done in resumed += 1;done?()}
 let token=PausedPlayback(bundle:"com.apple.Music",pid:123,track:"owned-track",position:42)
 avoidance.engage();pending?(.success(token));pending=nil;avoidance.restore()
 check(resumed==1 && avoidance.pausedToken==nil,"resume only owned pause token")
 avoidance.engage();pending?(.success(nil));pending=nil;avoidance.restore()
 check(resumed==1,"already paused player never receives resume")
 avoidance.engage();pending?(.success(token));pending=nil;avoidance.suppressResume=true;avoidance.restore()
 check(resumed==1,"player foreground/manual takeover suppresses automatic resume")
 avoidance.engage();avoidance.restore();pending?(.success(token));pending=nil
 check(resumed==2 && avoidance.pausedToken==nil,"late pause after cancellation is compensated")
 avoidance.engage();var finished=false;avoidance.shutdown{finished=true}
 check(!finished,"quit waits for in-flight pause ownership to resolve")
 pending?(.success(token));pending=nil
 check(finished && resumed==3,"quit resumes an owned late pause before terminating")
 print(failures==0 ? "PASS automation behavior and ownership":"FAIL \(failures) automation checks")
 return failures==0 ? 0:1
}

@MainActor func avoidanceIntegrationTest() async -> Int32 {
 let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build")
 var report=""
 func record(_ s:String){print(s);report+=s+"\n";try? report.write(to:root.appendingPathComponent("avoidance-integration.txt"),atomically:true,encoding:.utf8)}
 func wait(_ seconds:Double) async{try? await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
 let aPlayer=Process(),bPlayer=Process()
 let mixer=Mixer(testing:true)
 let a=Channel(id:"test.music."+UUID().uuidString,name:"测试音乐"),b=Channel(id:"test.trigger."+UUID().uuidString,name:"测试视频")
 let suite="local.tonedesk.test."+UUID().uuidString
 let defaults=UserDefaults(suiteName:suite)!
 let avoidance=MusicAvoidance(mixer:mixer,defaults:defaults)
 defer{
  avoidance.shutdown{}
  for c in [a,b]{c.saveWork?.cancel();c.stop();UserDefaults.standard.removeObject(forKey:"channel."+c.id);UserDefaults.standard.removeObject(forKey:"enabled."+c.id)}
  for p in [aPlayer,bPlayer] where p.isRunning{p.terminate()}
  defaults.removePersistentDomain(forName:suite)
 }
 guard let snap=decode(td_snapshot(),as:Snapshot.self),let output=snap.devices.first(where:{$0.id==snap.output})else{return 1}
 mixer.devices=snap.devices;mixer.output=snap.output;mixer.global.enabled=false;mixer.channels=[a,b]
 for (p,file) in [(aPlayer,"avoidance-music.wav"),(bPlayer,"avoidance-trigger.wav")]{
  p.executableURL=URL(fileURLWithPath:"/usr/bin/afplay");p.arguments=[root.appendingPathComponent(file).path]
  do{try p.run()}catch{record("FAIL test source: \(error)");return 2}
 }
 await wait(0.4)
 guard let now=decode(td_snapshot(),as:Snapshot.self),let pa=now.processes.first(where:{$0.pid==aPlayer.processIdentifier}),let pb=now.processes.first(where:{$0.pid==bPlayer.processIdentifier})else{record("FAIL discover synthetic sources");return 3}
 a.processes=[pa.id];a.sourceActive=true;a.config.volume=0.5;a.enabled=true;b.processes=[pb.id];b.enabled=false
 mixer.reconcile()
 for _ in 0..<30{if a.stream != nil{break};await wait(0.1)}
 guard let stream=a.stream else{record("FAIL music capture: \(a.status)");return 4}
 avoidance.enabled=true;avoidance.sourceID=a.id;avoidance.mode="lower";avoidance.amount=0.2;avoidance.delay=1;avoidance.allSources=false;avoidance.triggers=[b.id]
 avoidance.configure()
 await wait(0.8)
 let baseline=td_peak(stream)
 guard let monitor=avoidance.monitor else{record("FAIL activity monitor: \(avoidance.status)");return 5}
 record("Input monitor samples=\(td_monitor_frames(monitor)), music baseline=\(baseline)")
 guard baseline>0.00001,td_monitor_frames(monitor)>0,!avoidance.engaged else{record("FAIL quiet trigger must ignore playing music");return 6}
 for _ in 0..<60{if avoidance.engaged{break};await wait(0.1)}
 await wait(0.4)
 let ducked=td_peak(stream),duckOK=avoidance.engaged && abs(ducked/baseline-0.2)<0.06 && a.config.volume==0.5
 record("Ducked ratio=\(ducked/baseline), slider=\(a.config.volume), engaged=\(avoidance.engaged)")
 for _ in 0..<60{if !avoidance.engaged{break};await wait(0.1)}
 await wait(0.4)
 let restored=td_peak(stream)
 var globalError=[CChar](repeating:0,count:512)
 var musicID=pa.id
 let globalMonitor=td_monitor_start(&musicID,1,1,&globalError,512)
 await wait(0.3)
 let globalOK=globalMonitor.map{td_monitor_frames($0)>0} ?? false
 if let globalMonitor{td_monitor_stop(globalMonitor)}
 let after=decode(td_snapshot(),as:Snapshot.self)
 let deviceSame=after?.output==snap.output && after?.devices.first(where:{$0.id==snap.output})?.volume==output.volume
 let pass=duckOK && !avoidance.engaged && abs(restored/baseline-1)<0.08 && deviceSame && globalOK
 record("Restored ratio=\(restored/baseline), hardware unchanged=\(deviceSame), global monitor callbacks=\(globalOK)")
 record(pass ? "PASS real activity detection, duck/restore, excluded music, unchanged hardware":"FAIL avoidance integration")
 return pass ? 0:7
}

// Render the app-owned view in a hidden test window; no desktop capture or input.
@MainActor func settingsLayoutTest() async -> Int32 {
 let mixer=Mixer(testing:true)
 guard let snap=decode(td_snapshot(),as:Snapshot.self)else{return 1}
 mixer.devices=snap.devices;mixer.output=snap.output
 mixer.channels=[Channel(id:"com.apple.Music",name:"音乐"),Channel(id:"com.netease.163music",name:"网易云音乐"),Channel(id:"com.google.Chrome",name:"Google Chrome")]
 let suite="local.tonedesk.layout."+UUID().uuidString
 let defaults=UserDefaults(suiteName:suite)!
 defer{defaults.removePersistentDomain(forName:suite)}
 let priority=DevicePriority(defaults:defaults),avoidance=MusicAvoidance(mixer:mixer,defaults:defaults)
 priority.updateDevices(snap.devices,current:snap.output)
 let content=ScrollView{AutomationSettingsView(mixer:mixer,priority:priority,avoidance:avoidance)}.frame(width:360,height:600).background(Color(NSColor.windowBackgroundColor))
 let host=NSHostingView(rootView:content)
 let window=NSWindow(contentRect:NSRect(x:0,y:0,width:360,height:600),styleMask:.borderless,backing:.buffered,defer:false)
 window.contentView=host;host.setFrameSize(NSSize(width:360,height:600));host.layoutSubtreeIfNeeded()
 try? await Task.sleep(nanoseconds:300_000_000)
 host.layoutSubtreeIfNeeded();window.displayIfNeeded()
 guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds)else{return 2}
 host.cacheDisplay(in:host.bounds,to:rep)
 guard let data=rep.representation(using:.png,properties:[:])else{return 3}
 let path=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/settings-layout.png")
 do{try data.write(to:path)}catch{return 4}
 print("PASS settings view rendered 360×600: \(path.path), \(suite)");return 0
}
