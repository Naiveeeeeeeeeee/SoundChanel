import SwiftUI
import AppKit
import ServiceManagement

extension Mixer {
 func textPrompt(_ title:String,initial:String,placeholder:String="",message:String="")->String?{
  modalEditorActive=true;defer{modalEditorActive=false}
  let alert=NSAlert();alert.messageText=title;alert.informativeText=message
  let field=NSTextField(frame:NSRect(x:0,y:0,width:270,height:26));field.stringValue=initial;field.placeholderString=placeholder
  alert.accessoryView=field;alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
  alert.window.initialFirstResponder=field
  guard alert.runModal() == .alertFirstButtonReturn else{return nil}
  return field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
 }
 func promptSaveScene(){
  guard let name=textPrompt("保存音频配置",initial:"",placeholder:"例如：剪辑、听歌、会议"),!name.isEmpty else{return}
  scenes.append(captureScene(name:name));persistScenes()
 }
 func promptRenameScene(_ scene:AudioScene){
  guard let name=textPrompt("重命名配置",initial:scene.name),!name.isEmpty,let index=scenes.firstIndex(where:{$0.id==scene.id})else{return}
  scenes[index].name=name;persistScenes()
 }
 func updateScene(_ scene:AudioScene){guard let index=scenes.firstIndex(where:{$0.id==scene.id})else{return};var next=captureScene(name:scene.name);next.id=scene.id;scenes[index]=next;persistScenes()}
 func promptPercentage(_ title:String,current:Double,maximum:Int)->Double?{
  guard let text=textPrompt(title,initial:String(Int((current*100).rounded())),message:"请输入 0–\(maximum) 的整数百分比。")else{return nil}
  guard let value=Int(text.replacingOccurrences(of:"%",with:"").trimmingCharacters(in:.whitespaces)),(0...maximum).contains(value)else{message="音量须为 0–\(maximum) 的整数。";return nil}
  return Double(value)/100
 }
 func promptChannelVolume(_ channel:Channel){if let v=promptPercentage(channel.name+"音量",current:Double(channel.config.volume),maximum:200){setVolume(channel,Float(v))}}
 func promptDeviceVolume(_ device:Device?,kind:Int,current:Double){
  guard let v=promptPercentage(kind==1 ? "输入音量":kind==2 ? "提示音音量":"输出音量",current:current,maximum:100)else{return}
  if kind==2{setAlert(v)}else if let device{setDeviceVolume(device.id,input:kind==1,value:Float(v))}
 }
}

struct AutomationSettingsView:View {
 @ObservedObject var mixer:Mixer
 @ObservedObject var priority:DevicePriority
 @ObservedObject var avoidance:MusicAvoidance
 var choices:[(String,String)]{
  var values=Dictionary(uniqueKeysWithValues:mixer.channels.filter{!$0.id.hasPrefix("pid.")}.map{($0.id,$0.name)})
  if values[avoidance.sourceID]==nil{values[avoidance.sourceID]=NSWorkspace.shared.urlForApplication(withBundleIdentifier:avoidance.sourceID)?.deletingPathExtension().lastPathComponent ?? "已选择的音乐来源"}
  return values.map{($0.key,$0.value)}.sorted{$0.1.localizedStandardCompare($1.1) == .orderedAscending}
 }
 var body:some View{
  VStack(alignment:.leading,spacing:18){
   HStack{Text("设备与音乐").font(.system(size:20,weight:.semibold));Spacer();Button("完成"){mixer.showSettings=false}.keyboardShortcut(.defaultAction)}
   GroupBox{
    VStack(alignment:.leading,spacing:12){
     Toggle("自动选择输出设备",isOn:Binding(get:{priority.enabled},set:{priority.setEnabled($0);mixer.applyPriority()}))
     Text("越靠上越优先。手动切换后，会保留你的选择，直到设备连接变化或重新调整顺序。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).modifier(ControlFeedback())
     if priority.order.isEmpty{Text("尚未发现输出设备").font(.caption).foregroundStyle(.secondary)}
     ForEach(Array(priority.order.enumerated()),id:\.element.id){index,d in
      let connected=mixer.devices.contains{$0.uid==d.id && $0.outputs>0}
      HStack(spacing:8){
       Text("\(index+1)").font(.system(size:11,design:.rounded)).foregroundStyle(.secondary).frame(width:16)
       VStack(alignment:.leading,spacing:3){Text(d.name).font(.system(size:12,weight:.medium)).lineLimit(2);Text(connected ? "已连接":"未连接").font(.system(size:10)).foregroundStyle(connected ? Color.secondary:Color.secondary.opacity(0.6))}
       Spacer(minLength:0)
       Button{priority.move(d.id,-1);mixer.applyPriority()}label:{Image(systemName:"chevron.up")}.buttonStyle(FeedbackButton()).disabled(index==0).help("提高优先级")
       Button{priority.move(d.id,1);mixer.applyPriority()}label:{Image(systemName:"chevron.down")}.buttonStyle(FeedbackButton()).disabled(index==priority.order.count-1).help("降低优先级")
       if !connected{Button{priority.removeDisconnected(d.id,devices:mixer.devices);mixer.applyPriority()}label:{Image(systemName:"xmark")}.buttonStyle(FeedbackButton()).help("移除未连接的设备")}
      }.padding(.vertical,4)
     }
     if !priority.status.isEmpty{Text(priority.status).font(.caption).foregroundStyle(.secondary)}
    }.padding(8)
   }label:{Label("输出设备优先级",systemImage:"arrow.up.arrow.down")}
   GroupBox{
    VStack(alignment:.leading,spacing:12){
     Toggle("启用音乐避让",isOn:Binding(get:{avoidance.enabled},set:{avoidance.setEnabled($0)}))
     Picker("音乐来源",selection:Binding(get:{avoidance.sourceID},set:{avoidance.sourceID=$0;avoidance.settingsChanged()})){
      ForEach(choices,id:\.0){id,name in Text(name).tag(id)}
     }
     Picker("避让方式",selection:Binding(get:{avoidance.mode},set:{avoidance.mode=$0;avoidance.settingsChanged()})){
      Text("临时降低音量").tag("lower")
      Text("自动暂停播放").tag("pause").disabled(PlaybackControl.supported[avoidance.sourceID]==nil)
     }
     if avoidance.mode=="lower"{
      Picker("降低至原来的",selection:Binding(get:{avoidance.amount},set:{avoidance.amount=$0;avoidance.settingsChanged()})){
       ForEach([Float(0),0.1,0.2,0.3,0.5],id:\.self){v in Text("\(Int((v*100).rounded()))%").tag(v)}
      }
     }
     Picker("声音结束后恢复",selection:Binding(get:{avoidance.delay},set:{avoidance.delay=$0;avoidance.settingsChanged()})){
      ForEach([1.0,2,3,5],id:\.self){v in Text("\(Int(v)) 秒").tag(v)}
     }
     Picker("触发来源",selection:Binding(get:{avoidance.allSources},set:{avoidance.allSources=$0;avoidance.settingsChanged()})){
      Text("任意其他音源").tag(true);Text("仅指定的音源").tag(false)
     }
     if !avoidance.allSources{
      ForEach(choices.filter{$0.0 != avoidance.sourceID},id:\.0){id,name in
       Toggle(name,isOn:Binding(get:{avoidance.triggers.contains(id)},set:{v in if v{avoidance.triggers.insert(id)}else{avoidance.triggers.remove(id)};avoidance.settingsChanged()})).font(.system(size:11))
      }
     }
     Text(avoidance.status).font(.system(size:11,weight:.medium)).foregroundStyle(avoidance.engaged ? Color.teal:Color.secondary).fixedSize(horizontal:false,vertical:true).modifier(ControlFeedback())
     Text(avoidance.mode=="pause" ? "只恢复由声控台暂停的同一首音乐。切换曲目、跳转位置或回到播放器操作后，不会自动恢复。首次使用可能需要允许自动化控制。":"其他音源持续发声时临时降低音乐音量，结束后恢复。滑块百分比和已保存的配置保持不变。")
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).modifier(ControlFeedback())
     if PlaybackControl.supported[avoidance.sourceID]==nil{Text("此来源不提供受支持的暂停控制，可使用临时降低音量。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).modifier(ControlFeedback())}
    }.padding(8)
   }label:{Label("音乐自动避让",systemImage:"music.note")}
   GroupBox{
    VStack(alignment:.leading,spacing:12){
     Toggle("开机自启动",isOn:Binding(get:{mixer.login},set:{mixer.setLogin($0)}))
     if mixer.loginNeedsApproval{Button("打开登录项设置"){SMAppService.openSystemSettingsLoginItems()}}
     Toggle("全局快捷键",isOn:Binding(get:{mixer.hotkeys},set:{mixer.setHotkeys($0)}))
     Text("⌃⌥⌘ S 展开面板 · ↑↓ 调节输出 · M 静音").font(.caption).foregroundStyle(.secondary)
     Button("重新扫描音频插件"){mixer.plugins=decode(td_plugins(),as:[Plugin].self) ?? []}
     Button("打开系统音频权限"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)}
     Button("释放所有音频接管"){mixer.musicAvoidance.setEnabled(false);mixer.stopAll()}
     Button("退出声控台"){NSApp.terminate(nil)}
    }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
   }label:{Text("通用")}
   Text("声控台 \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")").font(.caption).foregroundStyle(.tertiary)
  }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
   .onAppear{priority.updateDevices(mixer.devices,current:mixer.output)}
 }
}
