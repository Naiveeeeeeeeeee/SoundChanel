import Foundation
import Combine

struct PreferredDevice: Codable, Identifiable, Equatable {
 var id:String
 var name:String
}

// Changes only on connection/order/enable events. A user's manual selection,
// including one made in System Settings, lasts until the next such event.
struct OutputPriorityPolicy {
 var previousConnected:Set<String>?
 var previousOrder:[String]=[]
 var previousEnabled=false
 var previousCurrent:String?
 var requested:String?
 var manual:String?
 mutating func selectedManually(_ uid:String){manual=uid;requested=nil;previousCurrent=uid}
 mutating func choose(connected:Set<String>,order:[String],current:String?,enabled:Bool)->String?{
  let event=previousConnected != connected || previousOrder != order || previousEnabled != enabled
  if event{manual=nil}
  else if let current,current != previousCurrent,current != requested{manual=current}
  defer{previousConnected=connected;previousOrder=order;previousEnabled=enabled;previousCurrent=current}
  guard enabled,event,manual==nil,let target=order.first(where:connected.contains),target != current else{return nil}
  requested=target;return target
 }
}

final class DevicePriority:ObservableObject {
 @Published var enabled:Bool
 @Published var order:[PreferredDevice]
 @Published var status=""
 let defaults:UserDefaults
 var policy=OutputPriorityPolicy()
 init(defaults:UserDefaults = .standard){
  self.defaults=defaults;enabled=defaults.bool(forKey:"priority.enabled")
  order=defaults.data(forKey:"priority.devices").flatMap{try? JSONDecoder().decode([PreferredDevice].self,from:$0)} ?? []
 }
 func persist(){defaults.set(enabled,forKey:"priority.enabled");if let data=try? JSONEncoder().encode(order){defaults.set(data,forKey:"priority.devices")}}
 func updateDevices(_ devices:[Device],current:UInt32){
  let outputs=devices.filter{$0.outputs>0}
  var next=order
  // Start with the user's current output first; do not invent an ordering by
  // device type or silently put a newly connected device at the top.
  let sorted=outputs.sorted{a,b in if a.id==current{return true};if b.id==current{return false};return a.name.localizedStandardCompare(b.name) == .orderedAscending}
  for d in sorted{
   if let index=next.firstIndex(where:{$0.id==d.uid}){next[index].name=d.name}
   else{next.append(PreferredDevice(id:d.uid,name:d.name))}
  }
  if next != order{order=next;persist()}
 }
 func setEnabled(_ value:Bool){enabled=value;persist()}
 func move(_ id:String,_ delta:Int){guard let index=order.firstIndex(where:{$0.id==id}),order.indices.contains(index+delta)else{return};order.swapAt(index,index+delta);persist()}
 func removeDisconnected(_ id:String,devices:[Device]){guard !devices.contains(where:{$0.uid==id})else{return};order.removeAll{$0.id==id};persist()}
 func nextDevice(devices:[Device],current:UInt32)->Device?{
  updateDevices(devices,current:current)
  let outputs=devices.filter{$0.outputs>0}
  let uid=policy.choose(connected:Set(outputs.map(\.uid)),order:order.map(\.id),current:outputs.first{$0.id==current}?.uid,enabled:enabled)
  return uid.flatMap{target in outputs.first{$0.uid==target}}
 }
}
