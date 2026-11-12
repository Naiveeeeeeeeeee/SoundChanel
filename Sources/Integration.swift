import Foundation
import AppKit
// Locate fixtures relative to the project, rather than a personal machine path.
// This keeps the CLI checks usable after moving the whole project folder.
func integrationBuildDirectory()->URL {
 let cwd=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
 var executable=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
 for _ in 0..<5{executable.deleteLastPathComponent()}
 let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
 let root=[cwd,executable,source].first{FileManager.default.fileExists(atPath:$0.appendingPathComponent("Sources/AudioBridge.mm").path)} ?? cwd
 return root.appendingPathComponent("build")
}
func integrationTest() -> Int32 {
 let folder=integrationBuildDirectory()
 let log=folder.appendingPathComponent("integration.txt")
 try? "".write(to:log,atomically:true,encoding:.utf8)
 func record(_ text:String){let h=try? FileHandle(forWritingTo:log);h?.seekToEndOfFile();h?.write(Data((text+"\n").utf8));try? h?.close();print(text)}
 let player=Process();player.executableURL=URL(fileURLWithPath:"/usr/bin/afplay");player.arguments=[folder.appendingPathComponent("test-tone.wav").path];do{try player.run()}catch{record(error.localizedDescription);return 1};defer{if player.isRunning{player.terminate()}}
 Thread.sleep(forTimeInterval:1)
 guard let snap=decode(td_snapshot(),as:Snapshot.self),let proc=snap.processes.first(where:{$0.pid==player.processIdentifier})else{record("FAIL no test audio process");return 2}
 record("Test source found. Creating tap; macOS may ask permission.")
 var error=[CChar](repeating:0,count:512);var id=proc.id
 guard let stream=td_start(&id,1,0,snap.output,&error,512)else{record("FAIL "+String(cString:error));return 3};var stopped=false;defer{if !stopped{td_stop(stream)}}
 let flat:[Float]=Array(repeating:0,count:10)
 func config(_ gain:Float,_ mute:Bool=false,_ eq:Bool=false,_ bands:[Float]?=nil){(bands ?? flat).withUnsafeBufferPointer{td_params(stream,gain,mute ? 1:0,0,0,eq ? 1:0,$0.baseAddress)}}
 func measure()->Float{Thread.sleep(forTimeInterval:0.4);var peak:Float=0;for _ in 0..<12{Thread.sleep(forTimeInterval:0.05);peak=max(peak,td_peak(stream))};return peak}
 config(0.5);var baseline=measure()
 for _ in 0..<30 {if baseline>0.00001{break};RunLoop.current.run(until:Date().addingTimeInterval(1));baseline=measure()}
 record("baseline=\(baseline), frames=\(td_frames(stream))")
 guard baseline>0.00001 else{record("FAIL silent buffers; permission or capture compatibility unresolved");return 4}
 config(0.25);let half=measure();record("half=\(half), ratio=\(half/baseline)")
 config(0.5,true);let silent=measure();record("mute=\(silent)")
 var bands=flat;bands[5]=6;config(0.5,false,true,bands);let eq=measure();record("EQ +6dB at 1kHz ratio=\(eq/baseline)")
 config(0.5)
 var pe=[CChar](repeating:0,count:512)
 // Apple's AULowpass. Loading verifies the generic Audio Unit processing path.
 let pluginStatus=td_plugin(stream,0x61756678,0x6c706173,0x6170706c,&pe,512)
 record("Apple AULowpass load=\(pluginStatus)")
 var chainOK=false
 if pluginStatus==0{
 _ = td_plugin_set(stream,0,700);let first=measure()
 let secondStatus=td_plugin_at(stream,1,0x61756678,0x6c706173,0x6170706c,&pe,512)
 _ = td_plugin_set_at(stream,1,0,700);let both=measure()
 td_bypass(stream,1);let bypass=measure();td_bypass(stream,0)
 chainOK=secondStatus==0 && first>0 && both>0 && abs(both/baseline-pow(first/baseline,2))<0.08 && abs(bypass/baseline-1)<0.08
 record("AU chain first=\(first/baseline), two=\(both/baseline), bypass=\(bypass/baseline), PASS=\(chainOK)")
 _ = td_plugin_at(stream,1,0,0,0,&pe,512);_ = td_plugin(stream,0,0,0,&pe,512)
 }
 td_stop(stream);stopped=true
 var globalOK=false
 if let now=decode(td_snapshot(),as:Snapshot.self){
 let excluded=now.processes.filter{$0.pid != player.processIdentifier}.map(\.id)
 var ge=[CChar](repeating:0,count:512)
 if let g=excluded.withUnsafeBufferPointer({td_start($0.baseAddress,Int32(excluded.count),1,now.output,&ge,512)}){
 flat.withUnsafeBufferPointer{td_params(g,0.5,0,0,0,0,$0.baseAddress)}
 Thread.sleep(forTimeInterval:1)
 let peak=td_peak(g);globalOK=td_frames(g)>0 && td_health(g)==0 && abs(peak/baseline-1)<0.15
 record("Global tap peak=\(peak), relative=\(peak/baseline), health=\(td_health(g))")
 td_stop(g)
 }else{record("Global FAIL "+String(cString:ge))}
 }
 let passed=globalOK && chainOK && abs(half/baseline-0.5)<0.08 && silent<0.000001 && abs(eq/baseline-1.995)<0.15 && pluginStatus==0
 record(passed ? "PASS real tap, gain, mute, EQ, Audio Unit. Releasing capture.":"FAIL measurement mismatch")
 return passed ? 0:5
}
func quickLookTest()->Int32 {
 let folder=integrationBuildDirectory()
 var log=""
 func record(_ line:String){log+=line+"\n";try? log.write(to:folder.appendingPathComponent("quicklook-test.txt"),atomically:true,encoding:.utf8)}
 guard let snap=decode(td_snapshot(),as:Snapshot.self)else{return 1}
 let ids=snap.processes.filter{$0.bundle=="local.source.quicklook"}.map(\.id)
 guard !ids.isEmpty else{record("FAIL Quick Look source not registered");return 2}
 var error=[CChar](repeating:0,count:512)
 guard let stream=ids.withUnsafeBufferPointer({td_start($0.baseAddress,Int32(ids.count),0,snap.output,&error,512)})else{record(String(cString:error));return 3}
 defer{td_stop(stream)}
 let flat=[Float](repeating:0,count:10)
 func config(_ gain:Float,_ mute:Int32=0){flat.withUnsafeBufferPointer{td_params(stream,gain,mute,0,0,0,$0.baseAddress)}}
 func measure()->Float{Thread.sleep(forTimeInterval:0.4);var peak:Float=0;for _ in 0..<10{Thread.sleep(forTimeInterval:0.05);peak=max(peak,td_peak(stream))};return peak}
 config(0.5);let baseline=measure();config(0.25);let half=measure();config(0.5,1);let silent=measure()
 record("Quick Look process IDs: \(ids), frames=\(td_frames(stream)), health=\(td_health(stream))")
 record("baseline=\(baseline), half=\(half), ratio=\(half/baseline), mute=\(silent)")
 let ok=baseline>0.00001 && abs(half/baseline-0.5)<0.08 && silent<0.000001 && td_health(stream)==0
 record(ok ? "PASS Quick Look capture / gain / mute (generated test sine)":"FAIL")
 return ok ? 0:4
}

// Exercise the same handlers used by the UI, with two independent audio clients.
@MainActor func controlPathTest() async -> Int32 {
 let root=integrationBuildDirectory()
 var report=""
 func record(_ line:String){report+=line+"\n";print(line);try? report.write(to:root.appendingPathComponent("control-path-test.txt"),atomically:true,encoding:.utf8)}
 func wait(_ seconds:Double) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))}
 let mixer=Mixer(testing:true)
 guard let snap=decode(td_snapshot(),as:Snapshot.self) else{return 1}
 mixer.devices=snap.devices;mixer.output=snap.output;mixer.global.enabled=false
 let a=Channel(id:"test."+UUID().uuidString,name:"测试音源 A")
 let b=Channel(id:"test."+UUID().uuidString,name:"测试音源 B")
 mixer.channels=[a,b]
 let players=(0..<2).map{_ in Process()}
 defer{for c in [a,b]{c.stop();UserDefaults.standard.removeObject(forKey:"channel."+c.id);UserDefaults.standard.removeObject(forKey:"enabled."+c.id)};for p in players where p.isRunning{p.terminate()}}
 mixer.setVolume(a,0.5);mixer.setVolume(b,0.5)
 guard a.enabled && b.enabled && a.status=="等待应用播放" else{record("FAIL editing idle source did not arm capture");return 2}
 for p in players{p.executableURL=URL(fileURLWithPath:"/usr/bin/afplay");p.arguments=[root.appendingPathComponent("test-tone.wav").path];do{try p.run()}catch{record("FAIL player \(error)");return 3}}
 await wait(1)
 guard let now=decode(td_snapshot(),as:Snapshot.self),let pa=now.processes.first(where:{$0.pid==players[0].processIdentifier}),let pb=now.processes.first(where:{$0.pid==players[1].processIdentifier})else{record("FAIL process discovery");return 4}
 a.processes=[pa.id];b.processes=[pb.id];mixer.reconcile()
 guard a.stream==nil && !a.starting && a.status=="等待应用播放" else{record("FAIL inactive client should wait for playback");return 8}
 a.sourceActive=pa.active;b.sourceActive=pb.active;mixer.reconcile()
 for _ in 0..<100{if a.stream != nil && b.stream != nil{break};await wait(0.1)}
 guard let sa=a.stream,let sb=b.stream else{record("FAIL connections: \(a.status), \(b.status)");return 5}
 await wait(1)
 let baseA=td_render_peak(sa),baseB=td_render_peak(sb)
 mixer.setVolume(a,0.25);await wait(1)
 let halfA=td_render_peak(sa),unchangedB=td_render_peak(sb)
 mixer.toggleMute(a);await wait(1)
 let silent=td_render_peak(sa),audibleB=td_render_peak(sb)
 mixer.toggleMute(a);mixer.setVolume(a,0.5);await wait(1)
 let restored=td_render_peak(sa)
 mixer.toggle(a,false);mixer.setVolume(a,0.25)
 for _ in 0..<100{if a.stream != nil{break};await wait(0.1)}
 await wait(1)
 let reenabled=a.stream.map{td_render_peak($0)} ?? 0
 var ok=baseA>0.00001 && baseB>0.00001 && abs(halfA/baseA-0.25)<0.02 && abs(unchangedB/baseB-1)<0.05 && silent==0 && abs(audibleB/baseB-1)<0.05 && abs(restored/baseA-1)<0.05 && abs(reenabled/baseA-0.25)<0.02 && td_health(sb)==0 && td_output_frames(sa)>48000 && td_output_frames(sb)>48000
 record("A baseline=\(baseA), half ratio=\(halfA/baseA), mute=\(silent), restored=\(restored/baseA), re-enabled=\(reenabled/baseA)")
 record("B unchanged ratio=\(unchangedB/baseB), while A muted=\(audibleB/baseB)")
 guard let live=a.stream else{return 7}
 // Measure the real output buffers, through the handlers used by the slider.
 // A runs at 100/50/10/5/1/0%; B must remain unchanged throughout.
 a.config.eq=true;a.apply()
 for value:Float in [1,0.5,0.1,0.05,0.01,0] {
  mixer.setVolume(a,value);await wait(0.4)
  var peak:Float=0
  for _ in 0..<12{peak=max(peak,td_render_peak(live));await wait(0.03)}
  let expected=td_volume_gain(value)/td_volume_gain(0.5)
  let ratio=peak/baseA
  let pass=(expected==0 ? peak==0:abs(ratio/expected-1)<0.05) && abs(td_render_peak(sb)/baseB-1)<0.05 && td_health(live)==0
  ok = ok && pass
  record("Slider \(Int(value*100))%: ratio=\(ratio), expected=\(expected), B=\(td_render_peak(sb)/baseB), PASS=\(pass)")
 }
 // Repeat low-volume checks with boost and an actual AU after the DSP.
 a.config.boost=true
 mixer.loadPlugin(a,Plugin(name:"Apple AULowpass",type:0x61756678,subtype:0x6c706173,manufacturer:0x6170706c),slot:0)
 mixer.setVolume(a,1);await wait(0.6);let effected=td_render_peak(live)
 mixer.setVolume(a,0.01);await wait(0.6);let low=td_render_peak(live)
 mixer.setVolume(a,0);await wait(0.6);let zero=td_render_peak(live)
 mixer.setVolume(a,1);mixer.toggleMute(a);await wait(0.6);let muted=td_render_peak(live)
 let effectOK=a.pluginAt(0) != nil && effected>0.00001 && abs((low/effected)/0.0001-1)<0.05 && zero==0 && muted==0
 ok = ok && effectOK
 record("Boost + AU final fader: 1% ratio=\(low/effected), 0%=\(zero), mute=\(muted), PASS=\(effectOK)")
 record(ok ? "PASS UI control handlers: idle activation, independent gain/mute, restore, re-enable":"FAIL control path")
 return ok ? 0:6
}

@MainActor func nativePlaybackTest() async -> Int32 {
 let mixer=Mixer(testing:true)
 guard let snap=decode(td_snapshot(),as:Snapshot.self) else{return 1}
 mixer.devices=snap.devices;mixer.output=snap.output;mixer.global.enabled=false
 let c=Channel(id:"test.native."+UUID().uuidString,name:"原生输出测试")
 c.config=Settings();c.enabled=false;mixer.channels=[c]
 let player=Process()
 defer{c.stop();c.saveWork?.cancel();UserDefaults.standard.removeObject(forKey:"channel."+c.id);UserDefaults.standard.removeObject(forKey:"enabled."+c.id);if player.isRunning{player.terminate()}}
 func wait(_ seconds:Double) async{try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))}
 mixer.toggle(c,true)
 guard !mixer.needsProcessing(c),c.stream==nil,!c.starting else{print("FAIL unity bypass");return 2}
 for key in 0..<7{
  c.config=Settings()
  switch key{case 0:c.config.volume=0.5;case 1:c.config.mute=true;case 2:c.config.eq=true;case 3:c.config.boost=true;case 4:c.config.balance=0.5;case 5:c.config.plugin=Plugin(name:"test",type:1,subtype:1,manufacturer:1);default:c.avoidanceGain=0.2}
  guard mixer.needsProcessing(c)else{print("FAIL processing policy",key);return 3}
 }
 c.config=Settings();c.avoidanceGain=1
 player.executableURL=URL(fileURLWithPath:"/usr/bin/afplay");player.arguments=[integrationBuildDirectory().appendingPathComponent("test-tone.wav").path]
 do{try player.run()}catch{return 4};await wait(0.8)
 guard let now=decode(td_snapshot(),as:Snapshot.self),let source=now.processes.first(where:{$0.pid==player.processIdentifier})else{return 5}
 c.processes=[source.id];c.sourceActive=true
 // A flat EQ deliberately keeps the unity processing path active for a real
 // native-output amplitude test. The normal 100% path above has no stream.
 c.config.eq=true;mixer.applyEdit(c)
 for _ in 0..<80{if c.stream != nil{break};await wait(0.05)}
 guard let stream=c.stream else{print("FAIL native output start",c.status);return 6}
 await wait(1)
 let capture=td_peak(stream),native=td_render_peak(stream)
 guard capture>0.0078,capture<0.0081,abs(native/capture-1)<0.02,td_output_frames(stream)>24000,td_health(stream)==0 else{print("FAIL unity",capture,native,td_output_frames(stream),td_health(stream));return 7}
 print("PASS native unity: capture=\(capture), rendered=\(native), ratio=\(native/capture), frames=\(td_output_frames(stream))")
 mixer.setVolume(c,0);await wait(0.5)
 guard td_render_peak(stream)==0 else{print("FAIL native zero");return 8}
 mixer.setVolume(c,0.5);await wait(0.5)
 guard abs(td_render_peak(stream)/native-0.25)<0.01 else{print("FAIL native fader");return 9}
 c.config.eq=false;mixer.setVolume(c,1)
 guard c.stream==nil,!c.starting,!mixer.needsProcessing(c)else{print("FAIL restore original playback");return 10}
 print("PASS native 0%, 50%; returning to 100% releases capture and restores original playback")
 // Exercise a real destination with a different rate if one is connected.
 if let other=snap.devices.first(where:{$0.outputs>0 && $0.id != snap.output && $0.rate != snap.devices.first(where:{$0.id==snap.output})?.rate}){
  c.config.outputUID=other.uid;mixer.setVolume(c,0.1)
  for _ in 0..<80{if c.stream != nil{break};await wait(0.05)}
  guard let routed=c.stream else{print("FAIL alternate native output",c.status);return 11}
  await wait(1)
  let ratio=td_render_peak(routed)/capture
  guard ratio>0.0095,ratio<0.0105,td_output_frames(routed)>10000,td_health(routed)==0 else{print("FAIL rate route",ratio,td_health(routed));return 12}
  print("PASS alternate native output \(other.name), \(other.rate) Hz, 10% rendered ratio=\(ratio)")
 }
 return 0
}

// Regression coverage for in-flight connection cancellation and transitions
// between original playback and native processed playback. No user settings
// or default devices are changed; only a generated quiet tone is played.
@MainActor func playbackTransitionTest() async -> Int32 {
 let mixer=Mixer(testing:true)
 guard let snap=decode(td_snapshot(),as:Snapshot.self)else{return 1}
 mixer.devices=snap.devices;mixer.output=snap.output;mixer.global.enabled=false
 let c=Channel(id:"test.transitions."+UUID().uuidString,name:"连接切换测试")
 c.config=Settings();c.enabled=false;mixer.channels=[c]
 let player=Process()
 defer{c.stop();c.saveWork?.cancel();UserDefaults.standard.removeObject(forKey:"channel."+c.id);UserDefaults.standard.removeObject(forKey:"enabled."+c.id);if player.isRunning{player.terminate()}}
 func wait(_ seconds:Double) async{try? await Task.sleep(nanoseconds:UInt64(seconds*1e9))}
 func settled() async->Bool{
  for _ in 0..<120{if !c.starting{return true};await wait(0.05)}
  return false
 }
 player.executableURL=URL(fileURLWithPath:"/usr/bin/afplay");player.arguments=[integrationBuildDirectory().appendingPathComponent("test-tone.wav").path]
 do{try player.run()}catch{return 2};await wait(0.6)
 guard let now=decode(td_snapshot(),as:Snapshot.self),let source=now.processes.first(where:{$0.pid==player.processIdentifier})else{return 3}
 c.processes=[source.id];c.sourceActive=true
 for _ in 0..<6{
  mixer.setVolume(c,0.4);mixer.setVolume(c,1)
  guard await settled(),c.stream==nil,!mixer.needsProcessing(c)else{print("FAIL stale connection after returning to unity");return 4}
 }
 print("PASS six rapid processing -> 100% changes: no stale connection retained")
 mixer.setVolume(c,0.4);mixer.pause()
 guard await settled(),c.stream==nil,mixer.paused else{return 5}
 await wait(0.3)
 guard c.stream==nil else{print("FAIL late connection survived pause");return 6}
 mixer.pause();guard await settled(),c.stream != nil else{return 7}
 await wait(0.5)
 guard td_output_frames(c.stream)>10000 else{return 8}
 print("PASS pause cancels pending connection; resume restores native callbacks")
 mixer.setVolume(c,1);mixer.toggleMute(c)
 guard await settled(),let muted=c.stream else{return 9}
 await wait(0.4)
 guard td_output_frames(muted)>0,td_render_peak(muted)==0 else{return 10}
 mixer.toggleMute(c)
 guard c.stream==nil,!mixer.needsProcessing(c)else{return 11}
 print("PASS mute at 100% is silent; unmute releases capture")
 let plugin=Plugin(name:"Apple AULowpass",type:0x61756678,subtype:0x6c706173,manufacturer:0x6170706c)
 mixer.loadPlugin(c,plugin,slot:0)
 guard await settled(),c.stream != nil,c.pluginAt(0) != nil else{return 12}
 await wait(0.4)
 guard td_output_frames(c.stream)>0,!c.pluginParams.isEmpty else{return 13}
 mixer.loadPlugin(c,nil,slot:0)
 guard c.stream==nil,!mixer.needsProcessing(c)else{return 14}
 print("PASS first plugin activates a bypassed channel; removing final plugin restores original playback")
 if let same=snap.devices.first(where:{$0.id==snap.output}){
  mixer.route(c,same.uid)
  guard c.stream==nil,!mixer.needsProcessing(c)else{return 15}
 }
 mixer.route(c,"");mixer.setVolume(c,0.25)
 guard await settled(),c.stream != nil else{return 16}
 mixer.toggle(c,false);await wait(0.2)
 guard c.stream==nil,!c.starting,!c.enabled else{return 17}
 print("PASS same-device routing remains native; releasing control destroys its stream")
 return 0
}
