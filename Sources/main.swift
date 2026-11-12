import Foundation
import AppKit
if CommandLine.arguments.contains("--playback-transition-test"){let testApp=NSApplication.shared;Task { @MainActor in exit(await playbackTransitionTest()) };testApp.run();exit(0)}
if CommandLine.arguments.contains("--native-playback-test"){let testApp=NSApplication.shared;Task { @MainActor in exit(await nativePlaybackTest()) };testApp.run();exit(0)}
if CommandLine.arguments.contains("--settings-layout-test"){let testApp=NSApplication.shared;Task { @MainActor in exit(await settingsLayoutTest()) };testApp.run();exit(0)}
if CommandLine.arguments.contains("--automation-test"){let testApp=NSApplication.shared;Task { @MainActor in exit(await automationTests()) };testApp.run();exit(0)}
if CommandLine.arguments.contains("--avoidance-integration-test"){let testApp=NSApplication.shared;Task { @MainActor in exit(await avoidanceIntegrationTest()) };testApp.run();exit(0)}
if CommandLine.arguments.contains("--audit-state-test"){let testApp=NSApplication.shared;Task { @MainActor in exit(await auditStateTest()) };testApp.run();exit(0)}
if CommandLine.arguments.contains("--ui-performance-test"){let testApp=NSApplication.shared;Task { @MainActor in exit(await volumeResponsivenessTest()) };testApp.run();exit(0)}
if CommandLine.arguments.contains("--slider-test"){
 var previous=0.0
 for i in 0...200{let v=Double(i)/100;let p=VolumeTravel.position(for:v);guard p>=previous && abs(VolumeTravel.volume(at:p)-v)<0.000001 else{exit(1)};previous=p}
 guard VolumeTravel.position(for:1)==0.85 && VolumeTravel.volume(at:0)==0 && VolumeTravel.volume(at:1)==2 && VolumeTravel.volume(at:0.425)==0.5 else{exit(2)}
 print("PASS slider mapping: 0–100% uses 85% travel; 100–200% uses 15%; all integer percentages round-trip");exit(0)
}
if CommandLine.arguments.contains("--login-status"){print("Launch at login:",LaunchAtLogin.statusName);exit(LaunchAtLogin.enabled ? 0:1)}
if CommandLine.arguments.contains("--enable-login"){do{try LaunchAtLogin.setEnabled(true);print("Launch at login:",LaunchAtLogin.statusName);exit(LaunchAtLogin.enabled ? 0:2)}catch{print("Launch at login failed:",error);exit(1)}}
if CommandLine.arguments.contains("--self-test"){let result=td_selftest();print("DSP tests:",result==0 ? "PASS":"FAIL \(result)");guard let snapshot=decode(td_snapshot(),as:Snapshot.self) else{print("Snapshot decode FAIL");exit(10)};print("Snapshot decode PASS: \(snapshot.devices.count) devices, \(snapshot.processes.count) processes");guard let plugins=decode(td_plugins(),as:[Plugin].self)else{exit(11)};print("Audio Units:",plugins.count);exit(result)}
if CommandLine.arguments.contains("--control-path-test"){let testApp=NSApplication.shared;Task { @MainActor in exit(await controlPathTest()) };testApp.run();exit(0)}
if CommandLine.arguments.contains("--integration-test"){let testApp=NSApplication.shared;DispatchQueue.global(qos:.userInitiated).async{exit(integrationTest())};testApp.run();exit(0)}
if CommandLine.arguments.contains("--chain-test"){exit(td_chain_test())}
if CommandLine.arguments.contains("--quicklook-test"){let testApp=NSApplication.shared;DispatchQueue.global(qos:.userInitiated).async{exit(quickLookTest())};testApp.run();exit(0)}
if CommandLine.arguments.contains("--snapshot"){if let p=td_snapshot(){print(String(cString:p));td_free(p)};exit(0)}
if CommandLine.arguments.contains("--alert-test"){
 guard let before=decode(td_snapshot(),as:Snapshot.self),let old=AlertVolume.read() else{exit(1)}
 defer{_ = AlertVolume.write(old)}
 let target=old == 37 ? 38:37
 let ok=AlertVolume.write(target)
 let after=decode(td_snapshot(),as:Snapshot.self)
 let hardwareBefore=before.devices.first{$0.id==before.output}?.volume
 let hardwareAfter=after?.devices.first{$0.id==before.output}?.volume
 let pass=ok && AlertVolume.read()==target && hardwareBefore==hardwareAfter
 print("Independent alert gain:",pass ? "PASS":"FAIL", "hardware before/after",hardwareBefore ?? -1,hardwareAfter ?? -1)
 _ = AlertVolume.write(old)
 exit(pass ? 0:1)
}
let app=NSApplication.shared
let delegate=Delegate()
app.delegate=delegate
app.setActivationPolicy(.accessory)
app.run()
