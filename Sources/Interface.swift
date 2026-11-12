import AppKit
import SwiftUI

enum VolumeTravel {
 static let unity = 0.85
 static func position(for volume: Double) -> Double {
  let v = volume.isFinite ? max(0, min(2, volume)) : 0
  return v <= 1 ? v * unity : unity + (v - 1) * (1 - unity)
 }
 static func volume(at position: Double) -> Double {
  let p = position.isFinite ? max(0, min(1, position)) : 0
  return p <= unity ? p / unity : 1 + (p - unity) / (1 - unity)
 }
}

enum PanelMetrics {
 static let main: CGFloat = 440
 static let detail: CGFloat = 360
 static let row: CGFloat = 34
 static let expanded: CGFloat = main + detail + 1
}

struct SoftCard: ViewModifier {
 @Environment(\.colorScheme) var scheme
 var radius: CGFloat = 16
 func body(content: Content) -> some View {
  content.background(Color.primary.opacity(scheme == .dark ? 0.055 : 0.035), in: RoundedRectangle(cornerRadius: radius))
   .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.5))
 }
}

// Shared state treatment for custom controls. Native bordered buttons and
// pickers keep their platform feedback; borderless controls opt in below.
struct ControlFeedback: ViewModifier {
 @Environment(\.isEnabled) private var enabled
 @Environment(\.isFocused) private var focused
 @ViewState private var hovered=false
 var selected=false
 var radius:CGFloat=7
 func body(content:Content)->some View{
  content.contentShape(RoundedRectangle(cornerRadius:radius))
   .background(Color.teal.opacity(enabled && selected ? (hovered ? 0.18:0.10):0),in:RoundedRectangle(cornerRadius:radius))
   .background(Color.primary.opacity(enabled && hovered && !selected ? 0.075:0),in:RoundedRectangle(cornerRadius:radius))
   .overlay(RoundedRectangle(cornerRadius:radius).strokeBorder(Color.teal.opacity(enabled && focused ? 0.7:0),lineWidth:1.5).allowsHitTesting(false))
   .onHover{hovered=enabled && $0}
   .onChange(of:enabled){_,active in if !active{hovered=false}}
 }
}
struct FeedbackButton:ButtonStyle{
 var selected=false
 func makeBody(configuration:Configuration)->some View{
  FeedbackButtonBody(configuration:configuration,selected:selected)
 }
}
private struct FeedbackButtonBody:View{
 let configuration:ButtonStyleConfiguration
 var selected:Bool
 @Environment(\.isEnabled) private var enabled
 var body:some View{
  configuration.label
   .background(Color.primary.opacity(enabled && configuration.isPressed ? 0.13:0),in:RoundedRectangle(cornerRadius:7))
   .modifier(ControlFeedback(selected:selected))
   .opacity(enabled ? 1:0.4)
 }
}
struct ToolButton: ButtonStyle {
 var selected = false
 func makeBody(configuration: Configuration) -> some View {
  ToolButtonBody(configuration:configuration,selected:selected)
 }
}
private struct ToolButtonBody:View{
 let configuration:ButtonStyleConfiguration
 var selected:Bool
 @Environment(\.isEnabled) private var enabled
 var body:some View{
  configuration.label.font(.system(size:11,weight:.medium))
   .foregroundStyle(selected ? Color.teal:Color.primary.opacity(0.7))
   .frame(width:23,height:23)
   .background(Color.primary.opacity(enabled && configuration.isPressed ? 0.15:0),in:RoundedRectangle(cornerRadius:7))
   .modifier(ControlFeedback(selected:selected))
   .opacity(enabled ? 1:0.35)
 }
}

// AppKit supplies the real desktop backdrop and native Liquid Glass. No opaque
// SwiftUI window fill is placed over it. Older macOS uses its native blur.
final class GlassPanelController: NSViewController {
 let hosting: NSHostingView<PanelContent>
 init(mixer: Mixer) {
  hosting = NSHostingView(rootView: PanelContent(mixer: mixer))
  super.init(nibName: nil, bundle: nil)
 }
 required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
 override func loadView() {
  let frame = NSRect(x: 0, y: 0, width: PanelMetrics.main, height: 640)
  hosting.frame = frame
  hosting.autoresizingMask = [.width, .height]
  if #available(macOS 26.0, *) {
   let glass = NSGlassEffectView(frame: frame)
   glass.style = .regular
   glass.cornerRadius = 22
   glass.contentView = hosting
   view = glass
  } else {
   let blur = NSVisualEffectView(frame: frame)
   blur.material = .popover
   blur.blendingMode = .behindWindow
   blur.state = .active
   blur.wantsLayer = true
   blur.layer?.cornerRadius = 22
   blur.layer?.masksToBounds = true
   blur.addSubview(hosting)
   view = blur
  }
 }
}

final class MixerPanel: NSPanel {
 var dismiss: (() -> Void)?
 override var canBecomeKey: Bool { true }
 override var canBecomeMain: Bool { false }
 override func cancelOperation(_ sender: Any?) { dismiss?() }
}
