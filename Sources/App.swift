import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Carbon
import Combine

// Explicit type alias keeps the property wrapper compatible with CLI SDKs
// that expose the newer State macro without shipping its compiler plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

struct Device: Codable, Identifiable, Hashable {
 var id:UInt32;var uid:String;var name:String;var inputs:Int;var outputs:Int;var volume:Float;var inputVolume:Float;var canVolume:Bool;var canInputVolume:Bool;var muted:Bool;var inputMuted:Bool;var canMute:Bool;var canInputMute:Bool;var rate:Double
}
struct ProcessInfoRow:Codable,Identifiable {var id:UInt32;var pid:Int32;var bundle:String;var name:String;var active:Bool}
struct Snapshot:Codable {var devices:[Device];var processes:[ProcessInfoRow];var output:UInt32;var input:UInt32;var effects:UInt32}
struct Plugin:Codable,Identifiable,Hashable {var name:String;var type:UInt32;var subtype:UInt32;var manufacturer:UInt32;var id:String{"\(type)-\(subtype)-\(manufacturer)"}}
struct PluginParameter:Codable,Identifiable {var id:UInt32;var name:String;var min:Float;var max:Float;var value:Float}
struct PluginSlot:Codable{var plugin:Plugin?;var values:[String:Float]?}
struct Settings:Codable {var volume:Float=1;var mute=false;var balance:Float=0;var boost=false;var eq=false;var bands:[Float]=Array(repeating:0,count:10);var outputUID="";var plugin:Plugin?=nil;var pluginValues:[String:Float]?=nil;var bypass:Bool?=nil;var extraPlugins:[PluginSlot]?=nil}
func decode<T:Decodable>(_ ptr:UnsafeMutablePointer<CChar>?,as type:T.Type)->T? {guard let ptr else{return nil};defer{td_free(ptr)};return try? JSONDecoder().decode(type,from:Data(String(cString:ptr).utf8))}

final class Channel:ObservableObject,Identifiable {
 let id:String;var name:String;var pid:Int32;var processes:[UInt32];var isGlobal:Bool
 @Published var config:Settings
 @Published var enabled=false
 var level:Float=0
 var avoidanceGain:Float=1
 var temporaryBaseGain:Float?
 var effectiveGain:Float{(temporaryBaseGain ?? td_volume_gain(config.volume))*avoidanceGain}
 var processingSettings:Settings{temporaryBaseGain==nil ? config:Settings()}
 var effectsBypassed:Bool{temporaryBaseGain != nil || config.bypass == true}
 @Published var status="未接管"
 @Published var pluginParams:[PluginParameter]=[]
 @Published var editSlot=0
 func pluginAt(_ slot:Int)->Plugin?{slot==0 ? config.plugin : (config.extraPlugins?.indices.contains(slot-1)==true ? config.extraPlugins?[slot-1].plugin:nil)}
 func valuesAt(_ slot:Int)->[String:Float]{slot==0 ? config.pluginValues ?? [:] : (config.extraPlugins?.indices.contains(slot-1)==true ? config.extraPlugins?[slot-1].values ?? [:]:[:])}
 func storePlugin(_ slot:Int,_ plugin:Plugin?,_ values:[String:Float]?){if slot==0{config.plugin=plugin;config.pluginValues=values}else{while (config.extraPlugins?.count ?? 0)<3{if config.extraPlugins==nil{config.extraPlugins=[]};config.extraPlugins?.append(PluginSlot())};config.extraPlugins?[slot-1]=PluginSlot(plugin:plugin,values:values)};save()}
 @Published var expanded=false
 var starting=false;var generation=0
 var sourceActive=false;var activeSince:Date?;var lastPlayed:Date?
 var muteDeadline:Date?;var muteRestore=false
 var stream:UnsafeMutableRawPointer?;var target:UInt32=0;var signature:[UInt32]=[];var sampleRate:Double=0;var startTime=Date();var hadSignal=false
 init(id:String,name:String,pid:Int32=0,processes:[UInt32]=[],global:Bool=false){self.id=id;self.name=name;self.pid=pid;self.processes=processes;isGlobal=global
 if let data=UserDefaults.standard.data(forKey:"channel."+id),let cfg=try? JSONDecoder().decode(Settings.self,from:data){config=cfg}else{config=Settings()};enabled=UserDefaults.standard.bool(forKey:"enabled."+id)}
 var saveWork:DispatchWorkItem?
 func save(){saveWork?.cancel();let work=DispatchWorkItem{[weak self] in self?.flushSave()};saveWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)}
 func flushSave(){saveWork?.cancel();saveWork=nil;if let data=try? JSONEncoder().encode(config){UserDefaults.standard.set(data,forKey:"channel."+id)}}
 func setStatus(_ value:String){if status != value{status=value}}
 func apply(){let active=processingSettings;active.bands.withUnsafeBufferPointer{td_params(stream,effectiveGain,active.mute ? 1:0,active.balance,(active.boost && !effectsBypassed) ? 1:0,(active.eq && !effectsBypassed) ? 1:0,$0.baseAddress)};td_bypass(stream,effectsBypassed ? 1:0);save()}
 func stop(){generation += 1;starting=false;if let s=stream{td_stop(s)};stream=nil;level=0;status="未接管";pluginParams=[]}
 deinit{saveWork?.cancel();if let s=stream{td_stop(s)}}
}

final class Mixer:ObservableObject {
 static let shared=Mixer()
 @Published var devices:[Device]=[];@Published var channels:[Channel]=[]
 @Published var output:UInt32=0;@Published var input:UInt32=0;@Published var effects:UInt32=0
 @Published var query="";@Published var message="";@Published var selected:String?=nil
 @Published var plugins:[Plugin]=[];@Published var paused=false
 @Published var login=false
 @Published var loginNeedsApproval=false
 @Published var hotkeys=false
 var hotkeyManager:HotKeys?
 var showPanelAction:(()->Void)?
 @Published var alertVolume:Double=1
 @Published var favorites:[String:String]=UserDefaults.standard.dictionary(forKey:"favorites") as? [String:String] ?? ["local.source.quicklook":"Finder · 空格预览"]
 @Published var showAll=UserDefaults.standard.bool(forKey:"showOtherApps.v3")
 @Published var showDevices=false
 @Published var showSettings=false
 @Published var pinned=false
 var modalEditorActive=false
 let deviceRouteQueue=DispatchQueue(label:"local.tonedesk.device-route",qos:.userInitiated)
 lazy var devicePriority=DevicePriority()
 lazy var musicAvoidance=MusicAvoidance(mixer:self)
 var isTesting=false
 func applyPriority(){
  guard !isTesting,let next=devicePriority.nextDevice(devices:devices,current:output)else{return}
  setDefaultDevice(next,kind:0,manual:false)
 }
 func setDefaultDevice(_ device:Device,kind:Int,manual:Bool=true){
  if kind==0 && manual{devicePriority.policy.selectedManually(device.uid)}
  deviceRevision += 1
  deviceRouteQueue.async{[weak self] in
   let result=td_default(device.id,Int32(kind))
   DispatchQueue.main.async{guard let self else{return};self.check(result,"切换设备");if result==0 && !manual{self.devicePriority.status="已切换到"+device.name};self.deviceRevision += 1;self.refresh()}
  }
 }
 let snapshotQueue=DispatchQueue(label:"local.tonedesk.snapshot",qos:.utility)
 var refreshInFlight=false
 var interactionDepth=0
 var hardwareWriteActive=false
 var deviceRevision=0
 var pendingDeviceVolumes:[DeviceVolumeKey:Float]=[:]
 var refreshCallbacks:[()->Void]=[]
 var snapshotCount=0
 lazy var volumeWriter:HardwareVolumeWriter={
  let writer=HardwareVolumeWriter()
  writer.onError={[weak self] code in self?.check(code,"调整音量")}
  writer.onIdle={[weak self] in guard let self,self.volumeWriter.isIdle else{return};self.hardwareWriteActive=false;if self.interactionDepth==0{self.refresh()}}
  return writer
 }()
 func beginInteraction(){interactionDepth += 1}
 func cancelInteractions(){interactionDepth=0;if !refreshCallbacks.isEmpty{refresh()}}
 func endInteraction(completion:(()->Void)?=nil){interactionDepth=max(0,interactionDepth-1);refresh(completion:completion)}
 func setDeviceVolume(_ id:UInt32,input:Bool,value:Float){deviceRevision += 1;hardwareWriteActive=true;let key=DeviceVolumeKey(device:id,input:input);pendingDeviceVolumes[key]=value;volumeWriter.submit(key,value)}
 @Published var panelVisible=false
 var runningIDs=Set<String>()
 var iconCache:[String:NSImage]=[:]
 let engineQueue=DispatchQueue(label:"local.tonedesk.start",qos:.userInitiated)
 var resizePanel:(()->Void)?
 var copiedEffects:Settings?
 @Published var scenes:[AudioScene]=(UserDefaults.standard.data(forKey:"scenes").flatMap{try? JSONDecoder().decode([AudioScene].self,from:$0)}) ?? []
 var alertWork:DispatchWorkItem?;var alertPrevious:Double=1

 let global=Channel(id:"system",name:"其余系统音频",global:true)
 var timer:Timer?;var meter:Timer?;var waking: NSObjectProtocol?;var sleeping:NSObjectProtocol?
 init(testing:Bool=false){
 isTesting=testing
 if testing{return}
 if !UserDefaults.standard.bool(forKey:"audioFavorites.seeded.v3"){
 for id in ["com.apple.Music","com.apple.Safari","com.google.Chrome","com.firecore.infuse","com.apple.FinalCut","com.tencent.QQMusicMac","com.netease.163music","com.lemon.lv"]{
 if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:id){let bundle=Bundle(url:url);favorites[id]=bundle?.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent}
 };UserDefaults.standard.set(favorites,forKey:"favorites");UserDefaults.standard.set(true,forKey:"audioFavorites.seeded.v3")
 }
 plugins=decode(td_plugins(),as:[Plugin].self) ?? [];login=SMAppService.mainApp.status == .enabled;refresh();timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true){[weak self]_ in self?.refresh()};meter=Timer.scheduledTimer(withTimeInterval:0.08,repeats:true){[weak self]_ in self?.meterTick()}
 setPanelVisible(false);timer?.tolerance=0.3
 sleeping=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self]_ in guard let self else{return};for c in self.channels+[self.global]{c.stop()}}
 waking=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self]_ in self?.restartAll()}
 }
 func setPanelVisible(_ visible:Bool){panelVisible=visible;if !visible{cancelInteractions()};meter?.invalidate();meter=Timer.scheduledTimer(withTimeInterval:visible ? 0.08:0.5,repeats:true){[weak self]_ in self?.meterTick()};meter?.tolerance=visible ? 0.02:0.15}
 func check(_ code:Int32,_ action:String){if code != 0{message="\(action)失败（\(code)）。设备可能不支持该操作。"}}
 func refresh(completion:(()->Void)?=nil){
  if let completion{refreshCallbacks.append(completion)}
  guard interactionDepth==0,!hardwareWriteActive,!refreshInFlight else{return}
  refreshInFlight=true;let revision=deviceRevision
  snapshotQueue.async{[weak self] in
   let snapshot=decode(td_snapshot(),as:Snapshot.self)
   DispatchQueue.main.async{guard let self else{return};self.refreshInFlight=false
    guard self.interactionDepth==0,!self.hardwareWriteActive,revision==self.deviceRevision else{if self.interactionDepth==0 && !self.hardwareWriteActive{self.refresh()};return}
    if let snapshot{self.snapshotCount += 1;self.acceptSnapshot(snapshot)}
    let callbacks=self.refreshCallbacks;self.refreshCallbacks.removeAll();callbacks.forEach{$0()}
   }
  }
 }
 func acceptSnapshot(_ snap:Snapshot){pendingDeviceVolumes.removeAll();refreshLogin();if devices != snap.devices{devices=snap.devices};if output != snap.output{output=snap.output};if input != snap.input{input=snap.input};if effects != snap.effects{effects=snap.effects}
 if alertWork == nil,let value=AlertVolume.read(),alertVolume != Double(value)/100{alertVolume=Double(value)/100}
 for (id,name) in favorites where !channels.contains(where:{$0.id==id}){channels.append(Channel(id:id,name:SpecialSource.names[id] ?? name))}
 let running=NSWorkspace.shared.runningApplications.filter{$0.activationPolicy == .regular && $0.bundleIdentifier != "local.tonedesk.app"}
 runningIDs=Set(running.compactMap{a in a.bundleIdentifier.map{$0 == "com.apple.finder" ? "local.source.quicklook":$0}})
 for app in running{guard let bundle=app.bundleIdentifier else{continue};let key=bundle == "com.apple.finder" ? "local.source.quicklook":bundle;if !channels.contains(where:{$0.id==key}){channels.append(Channel(id:key,name:SpecialSource.names[key] ?? app.localizedName ?? bundle,pid:app.processIdentifier))};if iconCache[key]==nil,let icon=app.icon{iconCache[key]=icon}}
 let groups=Dictionary(grouping:snap.processes.filter{!$0.bundle.hasPrefix("local.tonedesk")}){p in SpecialSource.key(p.bundle,pid:p.pid)}
 for(key,rows)in groups {if let c=channels.first(where:{$0.id==key}){c.processes=rows.map(\.id).sorted();c.pid=rows[0].pid;c.sourceActive=rows.contains{$0.active};if c.sourceActive{c.lastPlayed=Date();if c.activeSince==nil{c.activeSince=Date()}}else{c.activeSince=nil}}else{let app=NSRunningApplication(processIdentifier:rows[0].pid);let n=SpecialSource.names[key] ?? app?.localizedName ?? rows[0].name;if !n.isEmpty{channels.append(Channel(id:key,name:n,pid:rows[0].pid,processes:rows.map(\.id).sorted()))}}}
 for c in channels where groups[c.id]==nil{c.processes=[];c.sourceActive=false;c.activeSince=nil;if c.stream != nil{c.stop();c.status="等待应用播放"}}
 // Apply activity to newly discovered channels too, without waiting another poll.
 for c in channels{if let rows=groups[c.id],rows.contains(where:{$0.active}){c.sourceActive=true;c.lastPlayed=Date();if c.activeSince==nil{c.activeSince=Date()}}}
 let sorted=channels.sorted{let a=priority($0),b=priority($1);return a != b ? a<b : $0.name.localizedStandardCompare($1.name) == .orderedAscending};if sorted.map(\.id) != channels.map(\.id){channels=sorted}
 reconcile()
 if !isTesting{applyPriority();musicAvoidance.configure()}
 }
 func priority(_ c:Channel)->Int{
 if c.sourceActive{return 0}
 if let last=c.lastPlayed,Date().timeIntervalSince(last)<60{return 1}
 if favorites[c.id] != nil || c.enabled{return 2}
 // An audio client is more relevant than a merely running non-audio application.
 if !c.processes.isEmpty && runningIDs.contains(c.id) && SpecialSource.names[c.id]==nil{return 3}
 return 4
 }
 var primaryChannels:[Channel]{channels.filter{priority($0)<4}}
 var otherChannels:[Channel]{channels.filter{priority($0)==4 && runningIDs.contains($0.id)}}
 var visibleChannels:[Channel]{if !query.isEmpty{return channels.filter{$0.name.localizedCaseInsensitiveContains(query)}};return primaryChannels+(showAll ? otherChannels:[])}
 func icon(_ c:Channel)->NSImage?{if let icon=iconCache[c.id]{return icon};if SpecialSource.names[c.id] != nil{return nil};if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:c.id){let icon=NSWorkspace.shared.icon(forFile:url.path);iconCache[c.id]=icon;return icon};return nil}
 func pasteEffects(_ c:Channel){guard let saved=copiedEffects else{return};c.config.bands=saved.bands;c.config.eq=saved.eq;c.config.boost=saved.boost;c.config.balance=saved.balance;c.config.bypass=saved.bypass;c.config.extraPlugins=saved.extraPlugins;c.config.pluginValues=saved.pluginValues;c.config.plugin=saved.plugin;applyEdit(c);for slot in 0..<4{loadPlugin(c,c.pluginAt(slot),slot:slot)}}
 func meterTick(){for c in channels+[global]{if let until=c.muteDeadline, Date()>=until {c.muteDeadline=nil;c.config.mute=c.muteRestore;c.apply()};guard let s=c.stream else{continue};if td_health(s) != 0 || (c.sourceActive && Date().timeIntervalSince(c.activeSince ?? Date())>8 && td_frames(s)==0){c.stop();c.enabled=false;UserDefaults.standard.set(false,forKey:"enabled."+c.id);c.status="处理失败，已恢复原始播放";message=c.name+"：音频格式、插件或权限异常，已释放接管。";continue};let v=td_peak(s);c.level=max(v,c.level*0.8);if v>0.00001{c.hadSignal=true;c.setStatus("正在处理")}else if Date().timeIntervalSince(c.startTime)>8 && !c.hadSignal {c.setStatus(td_frames(s)>0 ? "已连接 · 等待音频 / 检查授权":"无音频回调 · 请检查授权")}}}
 func target(_ c:Channel)->UInt32{if c.temporaryBaseGain==nil && !c.config.outputUID.isEmpty{return devices.first{$0.uid==c.config.outputUID && $0.outputs>0}?.id ?? 0};return output}
 // At unity, native playback is exact: no tap, resampling or limiter.
 func needsProcessing(_ c:Channel)->Bool{
  let cfg=c.processingSettings
  if c.temporaryBaseGain != nil || c.avoidanceGain != 1 || cfg.volume != 1 || cfg.mute || cfg.balance != 0{return true}
  if !cfg.outputUID.isEmpty && target(c) != output{return true}
  return !c.effectsBypassed && (cfg.eq || cfg.boost || (0..<4).contains{c.pluginAt($0) != nil})
 }
 func reconcile(){guard !paused else{return};for c in channels where c.enabled && !c.starting{let t=target(c);
 if !needsProcessing(c){if c.stream != nil{c.stop()};c.setStatus("原始播放 · 100%");continue};if c.processes.isEmpty || (c.stream==nil && !c.sourceActive){c.status="等待应用播放";continue};if t==0{c.stop();c.status="输出设备未连接";continue};if c.stream==nil || t != c.target || c.signature != c.processes || c.sampleRate != devices.first(where:{$0.id==t})?.rate{start(c,ids:c.processes,target:t)}}
 if global.enabled && !global.starting{if !needsProcessing(global){if global.stream != nil{global.stop()};global.setStatus("原始播放 · 100%");return};let excluded=channels.filter{$0.stream != nil}.flatMap(\.processes).sorted();let t=target(global);if t==0{global.stop();global.status="输出设备未连接"}else if global.stream==nil || global.target != t || global.signature != excluded || global.sampleRate != devices.first(where:{$0.id==t})?.rate{start(global,ids:excluded,target:t)}}
 }
 func start(_ c:Channel,ids:[UInt32],target:UInt32){
 c.stop();c.starting=true;c.status="正在连接…";let token=c.generation;let isGlobal=c.isGlobal;let rate=devices.first(where:{$0.id==target})?.rate ?? 0;let initial=c.processingSettings;let initialGain=c.effectiveGain
 DispatchQueue.main.asyncAfter(deadline:.now()+10){[weak self,weak c] in guard let c,c.starting,c.generation==token else{return};c.generation += 1;c.starting=false;c.enabled=false;UserDefaults.standard.set(false,forKey:"enabled."+c.id);c.status="系统音频启动超时";self?.message="系统音频未及时响应，已取消启用；面板仍可使用。可退出其他音频处理器后重试。"}
 engineQueue.async{[weak self,weak c] in
 var error=[CChar](repeating:0,count:512);let stream=ids.withUnsafeBufferPointer{ids in initial.bands.withUnsafeBufferPointer{bands in td_start_configured(ids.baseAddress,Int32(ids.count),isGlobal ? 1:0,target,initialGain,initial.mute ? 1:0,initial.balance,(initial.boost && initial.bypass != true) ? 1:0,(initial.eq && initial.bypass != true) ? 1:0,bands.baseAddress,&error,512)}};let reason=String(cString:error)
 DispatchQueue.main.async{guard let self,let c,c.generation==token,c.enabled else{if let stream{DispatchQueue.global().async{td_stop(stream)}};return};c.starting=false
 guard let stream else{c.enabled=false;UserDefaults.standard.set(false,forKey:"enabled."+c.id);c.status=reason;self.message=reason;return}
 if !self.needsProcessing(c){td_stop(stream);c.setStatus("原始播放 · 100%");self.reconcile();return}
 c.stream=stream;c.target=target;c.sampleRate=rate;c.signature=ids;c.startTime=Date();c.hadSignal=false;c.status="已连接 · 等待音频";c.apply();for slot in 0..<4{if let plugin=c.pluginAt(slot){self.loadPlugin(c,plugin,slot:slot,userInitiated:false)}}
 self.reconcile()
 }
 }
 }
 // User edits must activate the processing path, including apps not playing yet.
 func applyEdit(_ c:Channel){
 if !isTesting{musicAvoidance.userEdited(c)}
 c.apply()
 if paused{message="音频处理已暂停，恢复处理后生效。"}
 if !c.enabled{toggle(c,true)}else{reconcile()}
 }
 func setVolume(_ c:Channel,_ value:Float){let rounded:Float=value.isFinite ? (max(0,min(2,value))*100).rounded()/100 : 0;guard c.config.volume != rounded || !c.enabled else{return};c.config.volume=rounded;applyEdit(c)}
 func toggleMute(_ c:Channel){c.muteDeadline=nil;c.config.mute.toggle();applyEdit(c)}
 func toggle(_ c:Channel,_ enabled:Bool){if !enabled && !isTesting{musicAvoidance.userDisabled(c)};c.enabled=enabled;UserDefaults.standard.set(enabled,forKey:"enabled."+c.id);if !enabled{c.stop()};reconcile()}
 func restartAll(){for c in channels+[global]{c.stop()};refresh()}
 func pause(){paused.toggle();for c in channels+[global]{c.stop()};if !paused{reconcile()};if !isTesting{musicAvoidance.configure()}}
 func stopAll(){for c in channels+[global]{toggle(c,false)}}
 func route(_ c:Channel,_ uid:String){c.config.outputUID=uid;applyEdit(c)}
 func loadPlugin(_ c:Channel,_ plugin:Plugin?,slot:Int?=nil,userInitiated:Bool=true){if userInitiated && !isTesting{musicAvoidance.userEdited(c);c.apply()};let index=slot ?? c.editSlot;let values=c.pluginAt(index)?.id==plugin?.id ? c.valuesAt(index):[:];c.storePlugin(index,plugin,values);if plugin != nil && (!c.enabled || c.stream==nil){applyEdit(c)};guard c.stream != nil else{return};var error=[CChar](repeating:0,count:512);let result=td_plugin_at(c.stream,Int32(index),plugin?.type ?? 0,plugin?.subtype ?? 0,plugin?.manufacturer ?? 0,&error,512);if result != 0{message=String(cString:error);c.storePlugin(index,nil,nil)}else{for (key,value) in values{if let id=UInt32(key){_ = td_plugin_set_at(c.stream,Int32(index),id,value)}}};if index==c.editSlot{c.pluginParams=decode(td_plugin_params_at(c.stream,Int32(index)),as:[PluginParameter].self) ?? []};reconcile()}
 func selectSlot(_ c:Channel,_ slot:Int){c.editSlot=slot;c.pluginParams=decode(td_plugin_params_at(c.stream,Int32(slot)),as:[PluginParameter].self) ?? []}
 func setHotkeys(_ enable:Bool){hotkeyManager?.clear();hotkeys=enable;UserDefaults.standard.set(enable,forKey:"hotkeys");guard enable else{return};if hotkeyManager==nil{hotkeyManager=HotKeys()};let registrations:[(UInt32,UInt32,()->Void)]=[(1,UInt32(kVK_ANSI_S),{[weak self] in self?.showPanelAction?()}),(2,UInt32(kVK_UpArrow),{[weak self] in self?.stepOutput(0.05)}),(3,UInt32(kVK_DownArrow),{[weak self] in self?.stepOutput(-0.05)}),(4,UInt32(kVK_ANSI_M),{[weak self] in guard let self,let d=self.devices.first(where:{$0.id==self.output})else{return};self.check(td_mute(d.id,0,d.muted ? 0:1),"静音输出");self.refresh()})];for (id,key,action) in registrations{if hotkeyManager?.register(id,key,action) != true{message="快捷键被其他程序占用，请关闭快捷键后重试。"}}}
 func stepOutput(_ delta:Float){guard let d=devices.first(where:{$0.id==output}),d.canVolume else{message="当前设备没有硬件音量，请调整应用音量。";return};setDeviceVolume(d.id,input:false,value:max(0,min(1,(pendingDeviceVolumes[DeviceVolumeKey(device:d.id,input:false)] ?? d.volume)+delta)))}
 func setAlert(_ v:Double){alertVolume=v;alertWork?.cancel();let work=DispatchWorkItem{[weak self] in guard let self else{return};if !AlertVolume.write(Int((self.alertVolume*100).rounded())){self.message="无法设置系统提示音音量"};self.alertWork=nil};alertWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.08,execute:work)}
 func favorite(_ c:Channel){if favorites[c.id] != nil{favorites.removeValue(forKey:c.id)}else{favorites[c.id]=c.name};UserDefaults.standard.set(favorites,forKey:"favorites");refresh()}
 func addSpecial(_ id:String){favorites[id]=SpecialSource.names[id];UserDefaults.standard.set(favorites,forKey:"favorites");refresh()}
 func addApp(){let panel=NSOpenPanel();panel.allowedContentTypes=[.application];panel.directoryURL=URL(fileURLWithPath:"/Applications");panel.canChooseDirectories=false;panel.begin{[weak self] result in guard result == .OK,let url=panel.url,let bundle=Bundle(url:url),let id=bundle.bundleIdentifier,let self else{return};self.favorites[id]=bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent;UserDefaults.standard.set(self.favorites,forKey:"favorites");self.refresh()}}
 func timedMute(_ c:Channel,_ seconds:Double){if !isTesting{musicAvoidance.userEdited(c)};if c.muteDeadline == nil{c.muteRestore=c.config.mute};c.muteDeadline=Date().addingTimeInterval(seconds);c.config.mute=true;toggle(c,true);c.apply()}
 func reset(_ c:Channel){if !isTesting{musicAvoidance.userEdited(c)};c.muteDeadline=nil;c.config=Settings();c.apply();for slot in 0..<4{loadPlugin(c,nil,slot:slot)};reconcile()}
 func captureScene(name:String)->AudioScene{
  let entries=(channels+[global]).map{SceneChannel(id:$0.id,name:$0.name,config:$0.config,enabled:$0.enabled && $0.temporaryBaseGain==nil)}
  let currentOutput=devices.first{$0.id==output},currentInput=devices.first{$0.id==input}
  return AudioScene(id:UUID().uuidString,name:name,channels:entries,output:currentOutput?.uid ?? "",input:currentInput?.uid ?? "",effects:devices.first{$0.id==effects}?.uid ?? "",
   volume:pendingDeviceVolumes[DeviceVolumeKey(device:output,input:false)] ?? currentOutput?.volume,
   inputVolume:pendingDeviceVolumes[DeviceVolumeKey(device:input,input:true)] ?? currentInput?.inputVolume,alert:alertVolume)
 }
 func saveScene(){scenes.append(captureScene(name:"配置 \(scenes.count+1) · \(Date().formatted(date:.omitted,time:.shortened))"));persistScenes()}
 func persistScenes(){if let data=try? JSONEncoder().encode(scenes){UserDefaults.standard.set(data,forKey:"scenes")}}
 func restoreScene(_ scene:AudioScene){if !isTesting{musicAvoidance.restore();musicAvoidance.stopMonitor()};paused=true;for c in channels+[global]{c.stop();c.enabled=false;UserDefaults.standard.set(false,forKey:"enabled."+c.id)};for (kind,uid) in [scene.output,scene.input,scene.effects].enumerated(){if let d=devices.first(where:{$0.uid==uid}){check(td_default(d.id,Int32(kind)),"切换配置设备")}}
 if let d=devices.first(where:{$0.uid==scene.output}),let v=scene.volume,v>=0{setDeviceVolume(d.id,input:false,value:v)};if let d=devices.first(where:{$0.uid==scene.input}),let v=scene.inputVolume,v>=0{setDeviceVolume(d.id,input:true,value:v)};setAlert(scene.alert)
 for entry in scene.channels{let c=(channels+[global]).first{$0.id==entry.id} ?? Channel(id:entry.id,name:entry.name);if c !== global && !channels.contains(where:{$0.id==c.id}){channels.append(c)};c.config=entry.config;c.muteDeadline=nil;c.enabled=entry.enabled;c.save();UserDefaults.standard.set(c.enabled,forKey:"enabled."+c.id)};paused=false;refresh()}
 func refreshLogin(){let enabled=LaunchAtLogin.enabled,approval=LaunchAtLogin.needsApproval;if login != enabled{login=enabled};if loginNeedsApproval != approval{loginNeedsApproval=approval}}
 func configureLogin(){do{try LaunchAtLogin.configureIfNeeded()}catch{message="开机自启动设置失败："+error.localizedDescription};refreshLogin();if loginNeedsApproval{message="开机自启动等待系统批准，请在系统设置 → 通用 → 登录项中允许声控台。"}}
 func setLogin(_ v:Bool){do{try LaunchAtLogin.setEnabled(v)}catch{message="开机自启动设置失败："+error.localizedDescription};refreshLogin();if loginNeedsApproval{message="开机自启动等待系统批准，请在系统设置 → 通用 → 登录项中允许声控台。"}}
}

struct DeviceCard: View {
 @ObservedObject var mixer:Mixer
 var kind:Int
 @ViewState<Double?> private var draft=nil
 @ViewState<Bool> private var editing=false
 var title:String{kind==1 ? "输入" : kind==2 ? "提示音" : "输出"}
 var deviceID:UInt32{kind==1 ? mixer.input : kind==2 ? mixer.effects : mixer.output}
 var device:Device?{mixer.devices.first{$0.id==deviceID}}
 var value:Double{kind==2 ? mixer.alertVolume : Double(max(0,kind==1 ? device?.inputVolume ?? 0 : device?.volume ?? 0))}
 var available:Bool{kind==2 || (kind==1 ? device?.canInputVolume ?? false : device?.canVolume ?? false)}
 var muted:Bool{kind==2 ? value==0 : kind==1 ? device?.inputMuted ?? false : device?.muted ?? false}
 var displayValue:Double{draft ?? value}
 var percentage:String{available ? "\(Int((displayValue*100).rounded()))%":"固定"}
 var deviceMenu:some View{
  Menu {
   ForEach(mixer.devices.filter{kind==1 ? $0.inputs>0 : $0.outputs>0}){d in Button(d.name){mixer.setDefaultDevice(d,kind:kind)}}
   if let d=device,kind != 2{Divider();Menu("采样率"){ForEach([44100,48000,88200,96000],id:\.self){r in Button("\(r) Hz"){mixer.check(td_rate(d.id,Double(r)),"设置采样率");mixer.restartAll()}}}}
  } label:{HStack(spacing:4){Text(device?.name ?? "无设备").lineLimit(1);Image(systemName:"chevron.down").font(.system(size:8,weight:.semibold))}}
  .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal:false,vertical:true).modifier(ControlFeedback())
 }
 var muteButton:some View{
  Button {
   if kind==2{if value>0{mixer.alertPrevious=value;mixer.setAlert(0)}else{mixer.setAlert(mixer.alertPrevious)}}
   else if let d=device{mixer.check(td_mute(d.id,kind==1 ? 1:0,(kind==1 ? d.inputMuted:d.muted) ? 0:1),"静音");mixer.refresh()}
  } label:{Image(systemName:muted ? "speaker.slash.fill":"speaker.wave.1.fill")}
  .buttonStyle(ToolButton(selected:muted)).disabled(kind != 2 && !(kind==1 ? device?.canInputMute ?? false : device?.canMute ?? false)).help("静音"+title)
 }
 var slider:some View{
  Slider(value:Binding(get:{displayValue},set:{v in draft=v;if kind==2{mixer.setAlert(v)}else if let d=device{mixer.setDeviceVolume(d.id,input:kind==1,value:Float(v))}}),in:0...1,onEditingChanged:{active in
   editing=active
   if active{mixer.beginInteraction()}
   else{mixer.endInteraction{if !editing{draft=nil}}}
  })
   .tint(.teal).controlSize(.mini).disabled(!available).accessibilityLabel(title+"音量")
   .onChange(of:value){_,_ in if !editing{draft=nil}}
   .onChange(of:mixer.panelVisible){_,visible in if !visible{editing=false;draft=nil}}
 }
 var body:some View{
  if kind==0{
   HStack(spacing:9){
    Image(systemName:"hifispeaker.fill").font(.system(size:13,weight:.medium)).foregroundStyle(.teal).frame(width:25,height:25).background(.teal.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
    deviceMenu.font(.system(size:11,weight:.medium)).frame(width:100,alignment:.leading)
    muteButton
    slider
    Button{mixer.promptDeviceVolume(device,kind:kind,current:displayValue)}label:{Text(percentage).font(.system(size:12,weight:.medium,design:.rounded)).monospacedDigit().foregroundStyle(.secondary).frame(width:32,alignment:.trailing)}.buttonStyle(FeedbackButton()).disabled(!available).help("输入音量百分比")
   }.padding(.horizontal,10).padding(.vertical,9).modifier(SoftCard(radius:13))
  }else{
   HStack(spacing:8){
    Image(systemName:kind==1 ? "mic.fill":"bell.fill").font(.system(size:13)).foregroundStyle(.secondary).frame(width:22)
    VStack(alignment:.leading,spacing:2){Text(title).font(.system(size:10)).foregroundStyle(.secondary);deviceMenu.font(.system(size:11,weight:.medium))}.frame(width:116,alignment:.leading)
    muteButton;slider
    Text(percentage).font(.system(size:11,design:.rounded)).monospacedDigit().foregroundStyle(.secondary).frame(width:36,alignment:.trailing)
   }.frame(height:38)
  }
 }
}
struct ChannelRow:View {
 @ObservedObject var channel:Channel
 @ObservedObject var mixer:Mixer
 @ViewState<Bool> private var hovered=false
 var appIcon:NSImage?{mixer.icon(channel)}
 var selected:Bool{mixer.selected==channel.id}
 var percentage:String{String(Int((channel.config.volume*100).rounded()))+"%"}
 var volumeBinding:Binding<Double>{Binding(get:{VolumeTravel.position(for:Double(channel.config.volume))},set:{mixer.setVolume(channel,Float(VolumeTravel.volume(at:$0)))})}
 var body:some View{
  HStack(spacing:6){
   ZStack(alignment:.bottomTrailing){
    Group{if let icon=appIcon{Image(nsImage:icon).resizable()}else{Image(systemName:SpecialSource.symbol(channel.id)).resizable().scaledToFit().padding(4).foregroundStyle(.teal)}}.frame(width:20,height:20)
    if channel.stream != nil{Circle().fill(channel.config.mute ? Color.orange:Color.teal).frame(width:5,height:5).overlay(Circle().stroke(.background,lineWidth:1)).offset(x:1,y:1)}
   }.accessibilityHidden(true)
   Button{mixer.selected=selected ? nil:channel.id}label:{
    HStack(spacing:3){Text(channel.name).lineLimit(1).truncationMode(.tail);Spacer(minLength:0);Image(systemName:"chevron.right").font(.system(size:8,weight:.semibold)).opacity(selected || hovered ? 0.6:0.2)}.frame(width:104,alignment:.leading)
   }.buttonStyle(FeedbackButton()).font(.system(size:11,weight:.medium)).help(channel.name+" · "+channel.status)
   Button{mixer.toggleMute(channel)}label:{Image(systemName:channel.config.mute ? "speaker.slash.fill":"speaker.wave.1.fill")}.buttonStyle(ToolButton(selected:channel.config.mute)).help("静音 "+channel.name+" · "+channel.status)
   // Keep the native continuous slider free of the 200 tick marks produced by
   // SwiftUI's step argument. The model still rounds edits to whole percent.
   Slider(value:volumeBinding,in:0...1,onEditingChanged:{$0 ? mixer.beginInteraction():mixer.endInteraction()})
    .controlSize(.mini).tint(channel.config.volume>1.005 ? Color.orange:Color.teal).accessibilityLabel(channel.name+"音量")
    .accessibilityValue(Text(percentage))
    .help("0–100% 占85%行程 · "+channel.status)
   Menu {
    Button("输入百分比…"){mixer.promptChannelVolume(channel)}
    Divider()
    ForEach([0,1,5,10,25,50,75,100,125,150,200],id:\.self){v in Button("\(v)%"){mixer.setVolume(channel,Float(v)/100)}}
   }label:{Text(percentage).font(.system(size:11,weight:.medium,design:.rounded)).monospacedDigit().foregroundStyle(channel.config.volume>1.005 ? Color.orange:Color.primary.opacity(0.7)).frame(width:39,alignment:.trailing)}
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().modifier(ControlFeedback()).help("选择音量百分比")
   Toggle("接管 "+channel.name,isOn:Binding(get:{channel.enabled},set:{mixer.toggle(channel,$0)})).labelsHidden().toggleStyle(.switch).modifier(ControlFeedback()).controlSize(.mini).tint(.teal).help(channel.status)
  }.padding(.horizontal,8).frame(height:PanelMetrics.row)
   .background(selected ? Color.teal.opacity(hovered ? 0.14:0.09):Color.primary.opacity(hovered ? 0.045:0),in:RoundedRectangle(cornerRadius:13))
   .onHover{hovered=$0}
   .contextMenu{
    if !channel.isGlobal{Button(mixer.favorites[channel.id] == nil ? "收藏置顶":"取消收藏"){mixer.favorite(channel)}}
    Button("音效与均衡器"){mixer.selected=channel.id}
    Button("恢复100%音量"){mixer.setVolume(channel,1)}
    Menu("定时静音"){ForEach([30,60,120,300],id:\.self){s in Button("\(s) 秒"){mixer.timedMute(channel,Double(s))}}}
    if channel.muteDeadline != nil{Button("取消定时静音"){channel.muteDeadline=nil;channel.config.mute=channel.muteRestore;mixer.applyEdit(channel)}}
    Toggle("旁路音效",isOn:Binding(get:{channel.config.bypass ?? false},set:{channel.config.bypass=$0;mixer.applyEdit(channel)}))
    Button("复制音效"){mixer.copiedEffects=channel.config}
    Button("粘贴音效"){mixer.pasteEffects(channel)}.disabled(mixer.copiedEffects==nil)
    Button("重置此音源"){mixer.reset(channel)}
   }
 }
}
struct EffectsView:View {
 @ObservedObject var channel:Channel;@ObservedObject var mixer:Mixer
 let frequencies=["31","63","125","250","500","1k","2k","4k","8k","16k"]
 func binding<T>(_ key:WritableKeyPath<Settings,T>)->Binding<T>{Binding(get:{channel.config[keyPath:key]},set:{channel.config[keyPath:key]=$0;mixer.applyEdit(channel)})}
 var body:some View{VStack(alignment:.leading,spacing:10){HStack{VStack(alignment:.leading){Text(channel.name).font(.system(size:16,weight:.semibold));Text(channel.status).font(.caption).foregroundStyle(.secondary)};Spacer();Button("完成"){mixer.selected=nil}.keyboardShortcut(.defaultAction)}
 Picker("输出设备",selection:Binding(get:{channel.config.outputUID},set:{mixer.route(channel,$0)})){Text("跟随系统").tag("");ForEach(mixer.devices.filter{$0.outputs>0}){Text($0.name).tag($0.uid)}}
 HStack{Button(mixer.favorites[channel.id] == nil ? "加入常用":"移出常用"){mixer.favorite(channel)};Spacer();Toggle("旁路音效",isOn:Binding(get:{channel.config.bypass ?? false},set:{channel.config.bypass=$0;mixer.applyEdit(channel)}))}
 HStack{Toggle("十段均衡器",isOn:binding(\.eq));Spacer();Menu("预设"){Button("平直"){preset(Array(repeating:0,count:10))};Button("人声清晰"){preset([-3,-2,-1,0,1,3,3,2,0,-1])};Button("低音增强"){preset([5,4,3,1,0,0,0,0,0,0])};Button("夜间柔和"){preset([-3,-2,0,1,2,1,0,-2,-3,-4])}}}
 HStack(spacing:4){ForEach(0..<10,id:\.self){i in VStack(spacing:8){Text(String(format:"%+.0f",channel.config.bands[i])).font(.system(.caption,design:.monospaced));Slider(value:Binding(get:{Double(channel.config.bands[i])},set:{channel.config.bands[i]=Float($0);mixer.applyEdit(channel)}),in:-12...12).rotationEffect(.degrees(-90)).frame(width:100,height:32).frame(width:28,height:100);Text(frequencies[i]).font(.caption2).foregroundStyle(.secondary)}}}.frame(height:150)
 Toggle("动态增强",isOn:binding(\.boost));Text("压缩大音量、抬升小音量，并限制峰值。").font(.caption).foregroundStyle(.secondary)
 HStack{Text("左");Slider(value:Binding(get:{Double(channel.config.balance)},set:{channel.config.balance=Float($0);mixer.applyEdit(channel)}),in:-1...1);Text("右");Button("居中"){channel.config.balance=0;mixer.applyEdit(channel)}}
 Divider();Text("Audio Unit 串联 · 从 1 到 4").font(.headline)
 Picker("插槽",selection:Binding(get:{channel.editSlot},set:{mixer.selectSlot(channel,$0)})){ForEach(0..<4,id:\.self){i in Text("\(i+1)"+(channel.pluginAt(i) == nil ? "":" •")).tag(i)}}.pickerStyle(.segmented)
 Picker("插件",selection:Binding(get:{channel.pluginAt(channel.editSlot)?.id ?? ""},set:{id in mixer.loadPlugin(channel,mixer.plugins.first{$0.id==id})})){Text("不使用").tag("");ForEach(mixer.plugins){Text($0.name).tag($0.id)}}.labelsHidden()
 if channel.stream==nil{Text("选择插件后自动连接；应用开始播放后生效。").font(.caption).foregroundStyle(.secondary)}
 ScrollView{VStack(alignment:.leading,spacing:10){ForEach(channel.pluginParams){p in if p.max>p.min {VStack(alignment:.leading){Text(p.name).font(.caption);Slider(value:Binding(get:{Double(channel.pluginParams.first{$0.id==p.id}?.value ?? p.value)},set:{v in if let i=channel.pluginParams.firstIndex(where:{$0.id==p.id}){channel.pluginParams[i].value=Float(v)};var values=channel.valuesAt(channel.editSlot);values[String(p.id)]=Float(v);channel.storePlugin(channel.editSlot,channel.pluginAt(channel.editSlot),values);mixer.applyEdit(channel);mixer.check(td_plugin_set_at(channel.stream,Int32(channel.editSlot),p.id,Float(v)),"设置插件参数")}),in:Double(p.min)...Double(p.max))}}}}}.frame(maxHeight:180)
 }.padding(14).frame(width:PanelMetrics.detail)}
 func preset(_ values:[Float]){channel.config.bands=values;channel.config.eq=true;mixer.applyEdit(channel)}
}
struct MixerView: View {
 @ObservedObject var mixer:Mixer
 var body:some View{
  VStack(spacing:0){
   HStack(spacing:10){
    Image(systemName:"waveform").font(.system(size:14,weight:.semibold)).foregroundStyle(.white).frame(width:28,height:28)
     .background(LinearGradient(colors:[Color(red:0.18,green:0.76,blue:0.72),Color(red:0.05,green:0.55,blue:0.57)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:11))
    Text("声控台").font(.system(size:14,weight:.semibold))
    Spacer(minLength:8)
    HStack(spacing:2){
     Menu{Button("保存当前配置…"){mixer.promptSaveScene()};ForEach(mixer.scenes){scene in Menu(scene.name){Button("载入"){mixer.restoreScene(scene)};Button("更新为当前配置"){mixer.updateScene(scene)};Button("重命名…"){mixer.promptRenameScene(scene)};Button("删除"){mixer.scenes.removeAll{$0.id==scene.id};mixer.persistScenes()}}}}label:{Image(systemName:"square.stack.3d.up").frame(width:24,height:26)}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().modifier(ControlFeedback()).accessibilityLabel("音频配置").help("音频配置")
     Button{mixer.pause()}label:{Image(systemName:mixer.paused ? "play.fill":"pause.fill")}.buttonStyle(ToolButton(selected:mixer.paused)).help(mixer.paused ? "恢复处理":"暂停处理").accessibilityLabel(mixer.paused ? "恢复处理":"暂停处理")
     Button{mixer.pinned.toggle()}label:{Image(systemName:mixer.pinned ? "pin.fill":"pin")}.buttonStyle(ToolButton(selected:mixer.pinned)).help("固定面板")
     Button{mixer.showSettings.toggle();mixer.selected=nil}label:{Image(systemName:"gearshape")}.buttonStyle(ToolButton(selected:mixer.showSettings)).help("设备与音乐设置").accessibilityLabel("设备与音乐设置")
    }.font(.system(size:13,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,5).padding(.vertical,3).background(.primary.opacity(0.035),in:Capsule())
   }.padding(.horizontal,14).padding(.top,10).padding(.bottom,8)
   if mixer.paused{Label("音频处理已暂停",systemImage:"pause.circle.fill").font(.system(size:11,weight:.medium)).foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,24).padding(.bottom,10)}
   if !mixer.message.isEmpty{
    HStack(alignment:.top,spacing:8){Image(systemName:"exclamationmark.circle");Text(mixer.message).font(.caption);Spacer();Button{mixer.message=""}label:{Image(systemName:"xmark")}.buttonStyle(FeedbackButton())}
     .foregroundStyle(.orange).padding(11).background(.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:13)).padding(.horizontal,18).padding(.bottom,10)
   }
   VStack(spacing:7){
    DeviceCard(mixer:mixer,kind:0)
    DisclosureGroup(isExpanded:$mixer.showDevices){
     VStack(spacing:0){DeviceCard(mixer:mixer,kind:2);if mixer.input != 0{DeviceCard(mixer:mixer,kind:1)}}.padding(.horizontal,7).padding(.top,4)
    }label:{Text("输入与提示音").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)}.tint(.secondary).padding(.horizontal,9)
   }.padding(.horizontal,15)
   HStack(spacing:9){
    Text("应用音量").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
    Spacer()
    HStack(spacing:5){
     Image(systemName:"magnifyingglass").foregroundStyle(.tertiary)
     TextField("搜索音源",text:$mixer.query).textFieldStyle(.plain).font(.system(size:11))
     if !mixer.query.isEmpty{Button{mixer.query=""}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(FeedbackButton()).foregroundStyle(.tertiary)}
    }.padding(.horizontal,8).frame(width:120,height:24).background(.primary.opacity(0.04),in:Capsule())
    Menu{Button("添加应用…"){mixer.addApp()};Divider();ForEach(SpecialSource.names.keys.sorted(),id:\.self){id in Button(SpecialSource.names[id]!){mixer.addSpecial(id)}}}label:{Image(systemName:"plus").font(.system(size:12,weight:.medium)).frame(width:22,height:22)}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().modifier(ControlFeedback()).background(.primary.opacity(0.04),in:Circle()).help("添加应用或系统音源")
   }.padding(.horizontal,19).padding(.top,9).padding(.bottom,4)
   ScrollView{
    LazyVStack(spacing:0){
     if mixer.visibleChannels.isEmpty{Text("暂无匹配音源").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.vertical,24)}
     ForEach(mixer.query.isEmpty ? mixer.primaryChannels:mixer.visibleChannels){ChannelRow(channel:$0,mixer:mixer)}
     if mixer.query.isEmpty && !mixer.otherChannels.isEmpty{
      Button{mixer.showAll.toggle();UserDefaults.standard.set(mixer.showAll,forKey:"showOtherApps.v3")}label:{HStack(spacing:6){Image(systemName:mixer.showAll ? "chevron.down":"chevron.right").font(.system(size:8,weight:.semibold));Text("其他运行应用");Text("\(mixer.otherChannels.count)").foregroundStyle(.tertiary);Spacer()}.font(.system(size:11,weight:.medium)).foregroundStyle(.secondary).frame(height:29).padding(.horizontal,10)}.buttonStyle(FeedbackButton())
      if mixer.showAll{ForEach(mixer.otherChannels){ChannelRow(channel:$0,mixer:mixer)}}
     }
    }.padding(.horizontal,12).padding(.bottom,4)
   }.scrollIndicators(.visible)
   VStack(spacing:0){
    Rectangle().fill(.primary.opacity(0.07)).frame(height:0.5).padding(.horizontal,12)
    ChannelRow(channel:mixer.global,mixer:mixer).padding(.vertical,5)
   }.padding(.horizontal,12).padding(.bottom,4)
  }.frame(width:PanelMetrics.main).frame(maxHeight:.infinity,alignment:.top).tint(.teal)
   .onChange(of:mixer.showDevices){_,_ in mixer.resizePanel?()}
   .onChange(of:mixer.showAll){_,_ in mixer.resizePanel?()}
   .onChange(of:mixer.query){_,_ in mixer.resizePanel?()}
   .onChange(of:mixer.visibleChannels.count){_,_ in mixer.resizePanel?()}
 }
}
struct PanelContent: View {
 @ObservedObject var mixer:Mixer
 var body:some View{
  HStack(spacing:0){
   MixerView(mixer:mixer)
   if mixer.showSettings{
    Rectangle().fill(.primary.opacity(0.08)).frame(width:1)
    ScrollView{AutomationSettingsView(mixer:mixer,priority:mixer.devicePriority,avoidance:mixer.musicAvoidance)}.frame(width:PanelMetrics.detail).frame(maxHeight:.infinity).background(.primary.opacity(0.025))
   }else if let c=(mixer.channels+[mixer.global]).first(where:{$0.id==mixer.selected}){
    Rectangle().fill(.primary.opacity(0.08)).frame(width:1)
    ScrollView{EffectsView(channel:c,mixer:mixer)}.frame(width:PanelMetrics.detail).frame(maxHeight:.infinity).background(.primary.opacity(0.025))
   }
  }.frame(width:mixer.selected != nil || mixer.showSettings ? PanelMetrics.expanded:PanelMetrics.main).frame(maxHeight:.infinity).tint(.teal)
 }
}
final class Delegate:NSObject,NSApplicationDelegate {
 var panel:MixerPanel!
 var item:NSStatusItem!
 var observations=Set<AnyCancellable>()
 var outsideMonitor:Any?
 var localMonitor:Any?
 var inactiveObserver:NSObjectProtocol?
 let mixer=Mixer.shared
 func applicationDidFinishLaunching(_ notification:Notification){
  panel=MixerPanel(contentRect:NSRect(x:0,y:0,width:PanelMetrics.main,height:640),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
  panel.level = .popUpMenu;panel.hidesOnDeactivate=false
  panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
  panel.contentViewController=GlassPanelController(mixer:mixer)
  panel.dismiss={[weak self] in self?.hidePanel()}
  item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
  item.button?.image=menuBarIcon();item.button?.toolTip="声控台 · 点击展开"
  item.button?.target=self;item.button?.action=#selector(togglePanel)
  mixer.resizePanel={[weak self] in self?.resize()}
  mixer.$selected.combineLatest(mixer.$showSettings).receive(on:RunLoop.main).sink{[weak self] _,_ in self?.resize()}.store(in:&observations)
  mixer.$paused.receive(on:RunLoop.main).sink{[weak self] _ in self?.resize()}.store(in:&observations)
  mixer.$message.receive(on:RunLoop.main).sink{[weak self] _ in self?.resize()}.store(in:&observations)
  outsideMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]){[weak self] _ in
   guard let self,self.panel.isVisible,!self.mixer.pinned,!self.mixer.modalEditorActive,!self.panel.frame.contains(NSEvent.mouseLocation)else{return};self.hidePanel()
  }
  localMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]){[weak self] event in
   if let self,self.panel.isVisible,!self.mixer.modalEditorActive,event.type == .keyDown,event.keyCode==53,event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty{self.hidePanel();return nil}
   if let self,self.panel.isVisible,!self.mixer.pinned,!self.mixer.modalEditorActive,let window=event.window,window !== self.panel,window.level.rawValue<NSWindow.Level.popUpMenu.rawValue{self.hidePanel()};return event
  }
  inactiveObserver=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main){[weak self] _ in guard let self,!self.mixer.pinned,!self.mixer.modalEditorActive else{return};self.hidePanel()}
  mixer.showPanelAction={[weak self] in self?.togglePanel()}
  for key in ["update.status","update.latest","update.attempt","update.automatic"]{UserDefaults.standard.removeObject(forKey:key)}
  mixer.setHotkeys(UserDefaults.standard.bool(forKey:"hotkeys"));mixer.configureLogin()
  if CommandLine.arguments.contains("--show-panel"){showPanel()}
 }
 @objc func togglePanel(){panel.isVisible ? hidePanel():showPanel()}
 func resize(){
  guard panel != nil,let button=item?.button,let window=button.window else{return}
  let screen=window.screen ?? NSScreen.main
  let available=screen?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
  let detailed=mixer.selected != nil || mixer.showSettings
  let extra:CGFloat=(mixer.showDevices ? (mixer.input == 0 ? 44:82):0)+(mixer.paused ? 28:0)+(mixer.message.isEmpty ? 0:58)
  let rows=CGFloat(mixer.visibleChannels.count)
  let h=min(600,min(available.height-24,max(320,detailed ? 590:190+PanelMetrics.row*rows+extra)))
  let w=detailed ? PanelMetrics.expanded:PanelMetrics.main
  let anchor=window.convertToScreen(button.convert(button.bounds,to:nil))
  let x=max(available.minX+12,min(anchor.maxX+8-w,available.maxX-w-12))
  let y=max(available.minY+12,anchor.minY-9-h)
  panel.setFrame(NSRect(x:x,y:y,width:w,height:h),display:panel.isVisible)
 }
 func showPanel(){resize();mixer.setPanelVisible(true);NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil);panel.makeFirstResponder(nil)}
 func hidePanel(){guard panel != nil else{return};panel.orderOut(nil);mixer.selected=nil;mixer.showSettings=false;mixer.setPanelVisible(false)}
 func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool{showPanel();return true}
 var waitingToQuit=false
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
  if waitingToQuit{return .terminateLater};waitingToQuit=true
  var replied=false
  let finish={if !replied{replied=true;sender.reply(toApplicationShouldTerminate:true)}}
  mixer.musicAvoidance.shutdown{DispatchQueue.main.async(execute:finish)}
  DispatchQueue.main.asyncAfter(deadline:.now()+4,execute:finish)
  return .terminateLater
 }
 func applicationWillTerminate(_ notification:Notification){
  if let outsideMonitor{NSEvent.removeMonitor(outsideMonitor)};if let localMonitor{NSEvent.removeMonitor(localMonitor)};if let inactiveObserver{NotificationCenter.default.removeObserver(inactiveObserver)}
  for c in mixer.channels+[mixer.global]{if c.muteDeadline != nil{c.config.mute=c.muteRestore};c.flushSave();c.stop()}
 }
}
