import AppKit
struct SceneChannel:Codable {var id:String;var name:String;var config:Settings;var enabled:Bool}
struct AudioScene:Codable,Identifiable {var id:String;var name:String;var channels:[SceneChannel];var output:String;var input:String;var effects:String;var volume:Float?;var inputVolume:Float?;var alert:Double}
// Standard Additions exposes independent alert volume; never write device gain here.
enum AlertVolume {
 static func run(_ source:String)->NSAppleEventDescriptor?{var error:NSDictionary?;let result=NSAppleScript(source:source)?.executeAndReturnError(&error);return error == nil ? result:nil}
 static func read()->Int?{run("alert volume of (get volume settings)").map{Int($0.int32Value)}}
 static func write(_ value:Int)->Bool{run("set volume alert volume \(max(0,min(100,value)))") != nil}
}
func menuBarIcon()->NSImage {
 let image=NSImage(size:NSSize(width:22,height:18),flipped:false){rect in
 NSColor.labelColor.setStroke()
 // Open acoustic ring with a small console fader: recognisable at 1x, no bitmap scaling.
 let ring=NSBezierPath();ring.lineWidth=1.5;ring.lineCapStyle = .round
 ring.appendArc(withCenter:NSPoint(x:10,y:9),radius:7,startAngle:55,endAngle:305,clockwise:false);ring.stroke()
 for (x,y,h) in [(6.0,6.5,5.0),(10.0,4.5,9.0),(14.0,7.0,4.0)]{
 let bar=NSBezierPath();bar.lineWidth=1.8;bar.lineCapStyle = .round;bar.move(to:NSPoint(x:x,y:y));bar.line(to:NSPoint(x:x,y:y+h));bar.stroke()
 }
 let rail=NSBezierPath();rail.lineWidth=1.3;rail.move(to:NSPoint(x:19,y:3));rail.line(to:NSPoint(x:19,y:15));rail.stroke()
 NSColor.labelColor.setFill();NSBezierPath(roundedRect:NSRect(x:16.8,y:9,width:4.4,height:3),xRadius:1,yRadius:1).fill()
 return true
 };image.isTemplate=true;image.accessibilityDescription="声控台";return image
}
enum SpecialSource {
 static let names=["local.source.quicklook":"Finder · 空格预览", "com.apple.controlcenter":"控制中心 / AirPlay 接收", "com.apple.notificationcenterui":"通知中心", "com.apple.accessibility.heard":"背景声音", "local.source.siri":"Siri", "local.source.speech":"朗读内容", "local.source.voiceover":"旁白 VoiceOver"]
 static func symbol(_ id:String)->String{switch id{case "local.source.quicklook":return "eye";case "com.apple.accessibility.heard":return "cloud.rain";case "local.source.siri":return "sparkles";case "local.source.speech":return "text.bubble";case "local.source.voiceover":return "person.wave.2";case "com.apple.controlcenter":return "switch.2";case "com.apple.notificationcenterui":return "bell.badge";case "system":return "waveform.path";default:return "speaker.wave.2"}}
 static func key(_ bundle:String,pid:Int32)->String {
 if ["com.apple.CoreSpeech","com.apple.sirittsd","com.apple.Siri"].contains(bundle){return "local.source.siri"}
 if ["com.apple.accessibility.AXVisualSupportAgent","com.apple.Accessibility-Settings.extension","com.apple.speech","com.apple.speech.speechsynthesisd","com.apple.speech.synthesis.SpeechSynthesisServer","com.apple.UniversalAccessControl"].contains(bundle){return "local.source.speech"}
 if ["com.apple.VoiceOver","com.apple.VoiceOverQuickstart"].contains(bundle){return "local.source.voiceover"}
 return bundle.isEmpty ? "pid.\(pid)":bundle
 }
}

// Carbon hot keys require no Accessibility keyboard monitoring permission.
import Carbon
final class HotKeys {
 static var actions:[UInt32:()->Void]=[:]
 var refs:[EventHotKeyRef]=[]
 var handler:EventHandlerRef?
 init(){var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed));InstallEventHandler(GetApplicationEventTarget(),{_,event,_ in
 var id=EventHotKeyID();let result=GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
 if result==noErr{HotKeys.actions[id.id]?()};return noErr
 },1,&type,nil,&handler)}
 func clear(){for ref in refs{UnregisterEventHotKey(ref)};refs=[];Self.actions=[:]}
 func register(_ id:UInt32,_ key:UInt32,_ action:@escaping()->Void)->Bool{var ref:EventHotKeyRef?;let status=RegisterEventHotKey(key,UInt32(controlKey|optionKey|cmdKey),EventHotKeyID(signature:0x544f4e45,id:id),GetApplicationEventTarget(),0,&ref);if status==noErr,let ref{refs.append(ref);Self.actions[id]=action;return true};return false}
 deinit{clear();if let handler{RemoveEventHandler(handler)}}
}
