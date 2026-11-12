#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <vector>
#include <libproc.h>
#include <cstring>
#include "AudioBridge.h"
#include "DSP.hpp"
#include "AudioRing.hpp"
static AudioObjectPropertyAddress addr(UInt32 s,UInt32 scope=kAudioObjectPropertyScopeGlobal,UInt32 e=kAudioObjectPropertyElementMain){return {s,scope,e};}
template<class T> static T get(AudioObjectID id,UInt32 key,T fallback={},UInt32 scope=kAudioObjectPropertyScopeGlobal,UInt32 el=0){auto a=addr(key,scope,el);UInt32 n=sizeof(T);T v=fallback;if(AudioObjectGetPropertyData(id,&a,0,nullptr,&n,&v))return fallback;return v;}
template<class T> static int set(AudioObjectID id,UInt32 key,T v,UInt32 scope=kAudioObjectPropertyScopeGlobal,UInt32 el=0){auto a=addr(key,scope,el);return AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(v),&v);}
static NSArray *ids(AudioObjectID id,UInt32 key,UInt32 scope=kAudioObjectPropertyScopeGlobal){auto a=addr(key,scope);UInt32 n=0;if(AudioObjectGetPropertyDataSize(id,&a,0,nullptr,&n))return @[];std::vector<AudioObjectID> v(n/4);if(AudioObjectGetPropertyData(id,&a,0,nullptr,&n,v.data()))return @[];NSMutableArray *out=[NSMutableArray array];for(auto i:v)[out addObject:@(i)];return out;}
static NSString *str(AudioObjectID id,UInt32 key){CFStringRef s=get<CFStringRef>(id,key,nullptr);return s?CFBridgingRelease(s):@"";}
static char *json(id obj){NSData*d=[NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];return strdup([[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding].UTF8String ?: "[]");}
static bool has(AudioObjectID id,UInt32 key,UInt32 scope,UInt32 el=0){auto a=addr(key,scope,el);Boolean yes=false;return AudioObjectHasProperty(id,&a)&&!AudioObjectIsPropertySettable(id,&a,&yes)&&yes;}
static int channels(AudioObjectID id,UInt32 scope){auto a=addr(kAudioDevicePropertyStreamConfiguration,scope);UInt32 n=0;if(AudioObjectGetPropertyDataSize(id,&a,0,nullptr,&n)||!n)return 0;std::vector<char>b(n);auto p=(AudioBufferList*)b.data();if(AudioObjectGetPropertyData(id,&a,0,nullptr,&n,p))return 0;int c=0;for(UInt32 i=0;i<p->mNumberBuffers;i++)c+=p->mBuffers[i].mNumberChannels;return c;}
static float volume(AudioObjectID id,UInt32 scope){float main=get<float>(id,kAudioHardwareServiceDeviceProperty_VirtualMainVolume,-1,scope);if(main>=0)return main;float v=get<float>(id,kAudioDevicePropertyVolumeScalar,-1,scope);if(v<0)v=get<float>(id,kAudioDevicePropertyVolumeScalar,-1,scope,1);return v;}
char *td_snapshot(){@autoreleasepool{
 NSMutableArray *devices=[NSMutableArray array],*processes=[NSMutableArray array];
 for(NSNumber*n in ids(kAudioObjectSystemObject,kAudioHardwarePropertyDevices)){AudioObjectID i=n.unsignedIntValue;NSString*uid=str(i,kAudioDevicePropertyDeviceUID);if([uid hasPrefix:@"ToneDesk."])continue;
 [devices addObject:@{@"id":n,@"uid":uid,@"name":str(i,kAudioObjectPropertyName),@"inputs":@(channels(i,kAudioDevicePropertyScopeInput)),@"outputs":@(channels(i,kAudioDevicePropertyScopeOutput)),@"volume":@(volume(i,kAudioDevicePropertyScopeOutput)),@"inputVolume":@(volume(i,kAudioDevicePropertyScopeInput)),@"canVolume":@(has(i,kAudioHardwareServiceDeviceProperty_VirtualMainVolume,kAudioDevicePropertyScopeOutput)||has(i,kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeOutput)||has(i,kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeOutput,1)),@"canInputVolume":@(has(i,kAudioHardwareServiceDeviceProperty_VirtualMainVolume,kAudioDevicePropertyScopeInput)||has(i,kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeInput)||has(i,kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeInput,1)),@"muted":@(get<UInt32>(i,kAudioDevicePropertyMute,0,kAudioDevicePropertyScopeOutput)!=0),@"inputMuted":@(get<UInt32>(i,kAudioDevicePropertyMute,0,kAudioDevicePropertyScopeInput)!=0),@"canMute":@(has(i,kAudioDevicePropertyMute,kAudioDevicePropertyScopeOutput)),@"canInputMute":@(has(i,kAudioDevicePropertyMute,kAudioDevicePropertyScopeInput)),@"rate":@(get<double>(i,kAudioDevicePropertyNominalSampleRate,48000))}];}
 for(NSNumber*n in ids(kAudioObjectSystemObject,kAudioHardwarePropertyProcessObjectList)){auto i=n.unsignedIntValue;pid_t pid=get<pid_t>(i,kAudioProcessPropertyPID,0);if(pid==getpid())continue;NSString*bundle=str(i,kAudioProcessPropertyBundleID);NSRunningApplication*a=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
 NSString *name=a.localizedName?:bundle;char exe[PROC_PIDPATHINFO_MAXSIZE]={};proc_pidpath(pid,exe,sizeof(exe));NSString*path=a.bundleURL.path?:[NSString stringWithUTF8String:exe];NSRange range=[path rangeOfString:@".app/"];if(path && range.location!=NSNotFound){NSBundle*parent=[NSBundle bundleWithPath:[path substringToIndex:range.location+4]];if(parent.bundleIdentifier){bundle=parent.bundleIdentifier;name=[parent objectForInfoDictionaryKey:@"CFBundleDisplayName"]?:[parent objectForInfoDictionaryKey:@"CFBundleName"]?:name;}}
 BOOL active=get<UInt32>(i,kAudioProcessPropertyIsRunningOutput,0)!=0;
 BOOL visible=a && a.activationPolicy==NSApplicationActivationPolicyRegular;
 // Keep system service sources discoverable even between playback bursts.
 if ([bundle isEqualToString:@"com.apple.finder"] || [bundle.lowercaseString containsString:@"quicklook"] || [path.lowercaseString containsString:@"quicklook"]) { bundle=@"local.source.quicklook"; name=@"快速查看 · 空格预览"; visible=YES; }
 if ([@[@"com.apple.CoreSpeech",@"com.apple.sirittsd",@"com.apple.Siri",@"com.apple.controlcenter",@"com.apple.notificationcenterui",@"com.apple.accessibility.heard",@"com.apple.speech.speechsynthesisd",@"com.apple.VoiceOver"] containsObject:bundle]) visible=YES;
 if(!visible&&!active)continue;
 [processes addObject:@{@"id":n,@"pid":@(pid),@"bundle":bundle,@"name":name,@"active":@(get<UInt32>(i,kAudioProcessPropertyIsRunningOutput,0)!=0)}];}
 return json(@{@"devices":devices,@"processes":processes,@"output":@(get<UInt32>(1,kAudioHardwarePropertyDefaultOutputDevice)),@"input":@(get<UInt32>(1,kAudioHardwarePropertyDefaultInputDevice)),@"effects":@(get<UInt32>(1,kAudioHardwarePropertyDefaultSystemOutputDevice))});}}
void td_free(char*p){free(p);}
int td_default(uint32_t d,int k){return set(1,k==1?kAudioHardwarePropertyDefaultInputDevice:k==2?kAudioHardwarePropertyDefaultSystemOutputDevice:kAudioHardwarePropertyDefaultOutputDevice,d);}
int td_volume(uint32_t d,int input,float v){UInt32 scope=input?kAudioDevicePropertyScopeInput:kAudioDevicePropertyScopeOutput;v=std::clamp(v,0.f,1.f);if(has(d,kAudioHardwareServiceDeviceProperty_VirtualMainVolume,scope))return set(d,kAudioHardwareServiceDeviceProperty_VirtualMainVolume,v,scope);if(has(d,kAudioDevicePropertyVolumeScalar,scope))return set(d,kAudioDevicePropertyVolumeScalar,v,scope);int result=-1;for(int c=1;c<=channels(d,scope);c++)if(has(d,kAudioDevicePropertyVolumeScalar,scope,c)){int s=set(d,kAudioDevicePropertyVolumeScalar,v,scope,c);if(s)return s;result=0;}return result;}
int td_mute(uint32_t d,int input,int mute){return set(d,kAudioDevicePropertyMute,UInt32(mute),input?kAudioDevicePropertyScopeInput:kAudioDevicePropertyScopeOutput);}
int td_rate(uint32_t d,double r){return set(d,kAudioDevicePropertyNominalSampleRate,r);}
struct Stream {
 AudioObjectID tap=0,device=0;AudioDeviceIOProcID proc=nullptr;DSP dsp;std::atomic<float> peak{0};std::atomic<uint64_t> frames{0};std::atomic<int> health{0};bool started=false;int inputOffset=0;
 AudioUnit outputUnit=nullptr;AudioRing ring;float captureStereo[16384]{},outputLeft[8192]{},outputRight[8192]{};std::atomic<uint64_t> outputFrames{0};std::atomic<float> renderPeak{0};
 std::atomic<bool> bypass{false};AudioUnit plugins[4]={};float left[8192]{},right[8192]{};struct {UInt32 count;AudioBuffer buffers[2];} abl;UInt32 currentFrames=0;double sampleTime=0;
 ~Stream(){if(outputUnit){AudioOutputUnitStop(outputUnit);AudioUnitUninitialize(outputUnit);AudioComponentInstanceDispose(outputUnit);}if(started)AudioDeviceStop(device,proc);if(proc)AudioDeviceDestroyIOProcID(device,proc);if(device)AudioHardwareDestroyAggregateDevice(device);if(tap)AudioHardwareDestroyProcessTap(tap);for(auto plugin:plugins)if(plugin){AudioUnitUninitialize(plugin);AudioComponentInstanceDispose(plugin);}}
};
static OSStatus provide(void*ref,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32 frames,AudioBufferList*data){Stream*s=(Stream*)ref;if(frames>s->currentFrames)return kAudio_ParamError;for(UInt32 i=0;i<data->mNumberBuffers;i++){data->mBuffers[i].mData=i?s->right:s->left;data->mBuffers[i].mNumberChannels=1;data->mBuffers[i].mDataByteSize=frames*4;}return noErr;}
static OSStatus io(AudioObjectID,const AudioTimeStamp*,const AudioBufferList*in,const AudioTimeStamp*,AudioBufferList*out,const AudioTimeStamp*,void*ref){
 auto*s=(Stream*)ref;for(UInt32 b=0;b<out->mNumberBuffers;b++)if(out->mBuffers[b].mData)memset(out->mBuffers[b].mData,0,out->mBuffers[b].mDataByteSize);
 if(!in||!out||!out->mNumberBuffers)return noErr;
 UInt32 frames=UINT32_MAX;for(UInt32 b=0;b<out->mNumberBuffers;b++)if(out->mBuffers[b].mNumberChannels)frames=std::min(frames,out->mBuffers[b].mDataByteSize/4/out->mBuffers[b].mNumberChannels);
 if(frames==UINT32_MAX||frames>8192){s->health=-10;return noErr;}
 // Aggregate hardware input channels precede the tap's stereo channels.
 const float*src[2]={};int stride[2]={};int channel=0;
 for(UInt32 b=0;b<in->mNumberBuffers;b++){auto&buf=in->mBuffers[b];for(UInt32 c=0;c<buf.mNumberChannels;c++,channel++){int t=channel-s->inputOffset;if(t>=0&&t<2&&buf.mData){src[t]=(const float*)buf.mData+c;stride[t]=buf.mNumberChannels;frames=std::min(frames,buf.mDataByteSize/4/buf.mNumberChannels);}}}
 if(!src[0]){s->health=-11;return noErr;}if(!src[1]){src[1]=src[0];stride[1]=stride[0];}
 s->dsp.update();float peak=0;for(UInt32 f=0;f<frames;f++){float l=src[0][f*stride[0]],r=src[1][f*stride[1]];s->dsp.processEffects(l,r);s->left[f]=l;s->right[f]=r;}
 for(auto plugin:s->plugins)if(plugin && !s->bypass){s->currentFrames=frames;s->abl.count=2;s->abl.buffers[0]={1,frames*4,s->left};s->abl.buffers[1]={1,frames*4,s->right};AudioTimeStamp ts{};ts.mFlags=kAudioTimeStampSampleTimeValid;ts.mSampleTime=s->sampleTime;AudioUnitRenderActionFlags flags=0;if(AudioUnitRender(plugin,&flags,&ts,0,frames,(AudioBufferList*)&s->abl)){s->health=-12;memset(s->left,0,frames*4);memset(s->right,0,frames*4);}}s->sampleTime+=frames;
 for(UInt32 f=0;f<frames;f++)s->dsp.processOutput(s->left[f],s->right[f]);
 channel=0;for(UInt32 b=0;b<out->mNumberBuffers;b++){auto&buf=out->mBuffers[b];if(!buf.mData){channel+=buf.mNumberChannels;continue;}float*dst=(float*)buf.mData;for(UInt32 c=0;c<buf.mNumberChannels;c++,channel++){for(UInt32 f=0;f<frames;f++){float v=channel==0?s->left[f]:channel==1?s->right[f]:0;if(!std::isfinite(v))v=0;v=std::clamp(v,-.98f,.98f);dst[f*buf.mNumberChannels+c]=v;peak=std::max(peak,fabsf(v));}}}
 s->peak.store(peak);s->frames.fetch_add(frames,std::memory_order_relaxed);return noErr;
}
// The aggregate is capture-only. Rendering through its output bypasses the
// normal device playback path on some macOS/drivers, so its system volume
// control can become ineffective. AUHAL plays as a normal physical-device
// client and lets that device apply its volume and mute exactly once.
static OSStatus capture_io(AudioObjectID device,const AudioTimeStamp*now,const AudioBufferList*in,const AudioTimeStamp*it,AudioBufferList*,const AudioTimeStamp*ot,void*ref){
 auto*s=(Stream*)ref;if(!in||!in->mNumberBuffers)return noErr;
 UInt32 frames=UINT32_MAX;
 for(UInt32 b=0;b<in->mNumberBuffers;b++){auto&buf=in->mBuffers[b];if(buf.mNumberChannels)frames=std::min(frames,buf.mDataByteSize/4/buf.mNumberChannels);}
 if(frames==UINT32_MAX||frames>8192){s->health=-10;return noErr;}
 AudioBufferList out{1,{{2,frames*8,s->captureStereo}}};
 auto status=io(device,now,in,it,&out,ot,ref);
 if(!status && !s->health.load())s->ring.push(s->left,s->right,frames);
 return status;
}
static OSStatus native_output(void*ref,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32 frames,AudioBufferList*out){
 auto*s=(Stream*)ref;if(!out)return noErr;
 for(UInt32 b=0;b<out->mNumberBuffers;b++)if(out->mBuffers[b].mData)memset(out->mBuffers[b].mData,0,out->mBuffers[b].mDataByteSize);
 if(frames>8192){s->health=-13;return noErr;}
 s->ring.render(s->outputLeft,s->outputRight,frames);
 UInt32 channel=0;for(UInt32 b=0;b<out->mNumberBuffers;b++){auto&buf=out->mBuffers[b];auto*dst=(float*)buf.mData;
 if(buf.mDataByteSize<frames*4*buf.mNumberChannels){s->health=-14;return noErr;}
 for(UInt32 c=0;c<buf.mNumberChannels;c++,channel++)if(dst)for(UInt32 f=0;f<frames;f++)dst[f*buf.mNumberChannels+c]=channel==0?s->outputLeft[f]:channel==1?s->outputRight[f]:0;
 }
 float peak=0;for(UInt32 f=0;f<frames;f++)peak=std::max(peak,std::max(fabsf(s->outputLeft[f]),fabsf(s->outputRight[f])));s->renderPeak=peak;
 s->outputFrames.fetch_add(frames,std::memory_order_relaxed);return noErr;
}
static void err(char*e,int n,const char*stage,OSStatus status){snprintf(e,n,"%s：%d",stage,(int)status);}
float td_volume_gain(float value){return volumeGain(value);}
void*td_start(const uint32_t*p,int count,int global,uint32_t output,char*error,int size){float bands[10]{};return td_start_configured(p,count,global,output,1,0,0,0,0,bands,error,size);}
void*td_start_configured(const uint32_t*p,int count,int global,uint32_t output,float gain,int mute,float balance,int boost,int eq,const float*bands,char*error,int size){@autoreleasepool{
 auto*s=new Stream;NSMutableArray*a=[NSMutableArray array];for(int i=0;i<count;i++)[a addObject:@(p[i])];
 td_params(s,gain,mute,balance,boost,eq,bands);
 if(global){for(NSNumber*n in ids(1,kAudioHardwarePropertyProcessObjectList))if(get<pid_t>(n.unsignedIntValue,kAudioProcessPropertyPID,0)==getpid())[a addObject:n];}
 CATapDescription*d=global?[[CATapDescription alloc]initStereoGlobalTapButExcludeProcesses:a]:[[CATapDescription alloc]initStereoMixdownOfProcesses:a];d.name=@"声控台";d.privateTap=YES;d.muteBehavior=CATapMutedWhenTapped;
 OSStatus status=AudioHardwareCreateProcessTap(d,&s->tap);if(status){err(error,size,"创建音频接管失败",status);delete s;return nullptr;}
 NSString*uid=str(output,kAudioDevicePropertyDeviceUID);if(!uid.length){err(error,size,"输出设备已断开",-1);delete s;return nullptr;}
 // Initialise the native output first so global capture can exclude our
 // process even when this is the first routed channel.
 AudioComponentDescription component={kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};
 auto found=AudioComponentFindNext(nullptr,&component);
 status=found?AudioComponentInstanceNew(found,&s->outputUnit):-1;
 if(!status)status=AudioUnitSetProperty(s->outputUnit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&output,sizeof(output));
 double outputRate=get<double>(output,kAudioDevicePropertyNominalSampleRate,48000);
 AudioStreamBasicDescription format{};format.mSampleRate=outputRate;format.mFormatID=kAudioFormatLinearPCM;format.mFormatFlags=kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved;format.mBytesPerPacket=4;format.mFramesPerPacket=1;format.mBytesPerFrame=4;format.mChannelsPerFrame=2;format.mBitsPerChannel=32;
 UInt32 maxFrames=8192;AURenderCallbackStruct cb={native_output,s};
 if(!status)status=AudioUnitSetProperty(s->outputUnit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&format,sizeof(format));
 if(!status)status=AudioUnitSetProperty(s->outputUnit,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&maxFrames,sizeof(maxFrames));
 if(!status)status=AudioUnitSetProperty(s->outputUnit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof(cb));
 if(!status)status=AudioUnitInitialize(s->outputUnit);
 if(status){err(error,size,"初始化原生输出失败",status);delete s;return nullptr;}
 NSDictionary*desc=@{@kAudioAggregateDeviceNameKey:@"ToneDesk Capture",@kAudioAggregateDeviceUIDKey:[@"ToneDesk." stringByAppendingString:NSUUID.UUID.UUIDString],@kAudioAggregateDeviceIsPrivateKey:@YES,@kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:d.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}],@kAudioAggregateDeviceTapAutoStartKey:@YES};
 status=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)desc,&s->device);if(status){err(error,size,"创建音频捕获失败",status);delete s;return nullptr;}
 if(global){NSMutableArray *excluded=[a mutableCopy];for(NSNumber*n in ids(1,kAudioHardwarePropertyProcessObjectList))if(get<pid_t>(n.unsignedIntValue,kAudioProcessPropertyPID,0)==getpid() && ![excluded containsObject:n])[excluded addObject:n];d.processes=excluded;status=set(s->tap,kAudioTapPropertyDescription,d);if(status){err(error,size,"设置自身音频排除失败",status);delete s;return nullptr;}}
 // Let HAL drift-compensate/resample the tap to the native device rate.
 // The ring also handles mismatched-rate drivers that reject this request.
 set(s->device,kAudioDevicePropertyNominalSampleRate,outputRate);
 s->dsp.sr=get<double>(s->device,kAudioDevicePropertyNominalSampleRate,48000);s->inputOffset=0;
 for(NSNumber*n in ids(s->device,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeInput)){auto f=get<AudioStreamBasicDescription>(n.unsignedIntValue,kAudioStreamPropertyVirtualFormat);if(f.mFormatID!=kAudioFormatLinearPCM||!(f.mFormatFlags&kAudioFormatFlagIsFloat)||f.mBitsPerChannel!=32){err(error,size,"捕获不支持 Float32 PCM",-2);delete s;return nullptr;}}
 s->ring.configure(s->dsp.sr,outputRate,get<UInt32>(output,kAudioDevicePropertyBufferFrameSize,512));
 status=AudioDeviceCreateIOProcID(s->device,capture_io,s,&s->proc);if(!status)status=AudioDeviceStart(s->device,s->proc);
 if(status){err(error,size,"启动音频捕获失败，请检查系统音频权限",status);delete s;return nullptr;}s->started=true;
 status=AudioOutputUnitStart(s->outputUnit);if(status){err(error,size,"启动原生播放失败",status);delete s;return nullptr;}
 return s;
}}
void td_stop(void*p){delete (Stream*)p;}
void td_params(void*p,float gain,int mute,float balance,int boost,int eq,const float*bands){if(!p)return;auto*s=(Stream*)p;s->dsp.gain=std::clamp(gain,0.f,4.f);s->dsp.mute=mute;s->dsp.balance=std::clamp(balance,-1.f,1.f);s->dsp.boost=boost;s->dsp.eq=eq;for(int i=0;i<10;i++)s->dsp.bands[i]=std::clamp(bands[i],-12.f,12.f);}
float td_render_peak(void*p){return p?((Stream*)p)->renderPeak.load():0;}
uint64_t td_output_frames(void*p){return p?((Stream*)p)->outputFrames.load():0;}
int td_health(void*p){return p?((Stream*)p)->health.load():0;}
float td_peak(void*p){return p?((Stream*)p)->peak.load():0;}
uint64_t td_frames(void*p){return p?((Stream*)p)->frames.load():0;}
char *td_plugins(){@autoreleasepool{NSMutableArray*a=[NSMutableArray array];for(OSType type:{kAudioUnitType_Effect,kAudioUnitType_MusicEffect}){AudioComponentDescription d={type,0,0,0,0};AudioComponent c=nullptr;while((c=AudioComponentFindNext(c,&d))){AudioComponentDescription info{};AudioComponentGetDescription(c,&info);CFStringRef name=nullptr;AudioComponentCopyName(c,&name);NSString*n=name?CFBridgingRelease(name):@"Audio Unit";[a addObject:@{@"name":n,@"type":@(info.componentType),@"subtype":@(info.componentSubType),@"manufacturer":@(info.componentManufacturer)}];}}return json(a);}}
int td_plugin_at(void*p,int slot,uint32_t type,uint32_t subtype,uint32_t manufacturer,char*error,int size){auto*s=(Stream*)p;if(!s||slot<0||slot>=4)return -1;auto &plugin=s->plugins[slot];if(s->outputUnit)AudioOutputUnitStop(s->outputUnit);if(s->device)AudioDeviceStop(s->device,s->proc);s->started=false;int status=0;
 if(plugin){AudioUnitUninitialize(plugin);AudioComponentInstanceDispose(plugin);plugin=nullptr;}
 if(type){AudioComponentDescription d={type,subtype,manufacturer,0,0};AudioComponent c=AudioComponentFindNext(nullptr,&d);if(!c)status=-1;else status=AudioComponentInstanceNew(c,&plugin);
 if(!status){AudioStreamBasicDescription f={};f.mSampleRate=s->dsp.sr;f.mFormatID=kAudioFormatLinearPCM;f.mFormatFlags=kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved;f.mBytesPerPacket=4;f.mFramesPerPacket=1;f.mBytesPerFrame=4;f.mChannelsPerFrame=2;f.mBitsPerChannel=32;UInt32 max=8192;
 status=AudioUnitSetProperty(plugin,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&f,sizeof(f));if(!status)status=AudioUnitSetProperty(plugin,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&f,sizeof(f));
 AudioUnitSetProperty(plugin,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&max,sizeof(max));AURenderCallbackStruct cb={provide,s};if(!status)status=AudioUnitSetProperty(plugin,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof(cb));if(!status)status=AudioUnitInitialize(plugin);}
 if(status&&plugin){AudioComponentInstanceDispose(plugin);plugin=nullptr;}}
 int restart=s->device?AudioDeviceStart(s->device,s->proc):0;s->started=s->device&&!restart;if(restart)status=restart;if(s->outputUnit){int out=AudioOutputUnitStart(s->outputUnit);if(out)status=out;}if(status)err(error,size,"插件加载或恢复音频失败",status);return status;}
char*td_plugin_params_at(void*p,int slot){@autoreleasepool{NSMutableArray*a=[NSMutableArray array];auto*s=(Stream*)p;if(!s||slot<0||slot>=4||!s->plugins[slot])return json(a);auto plugin=s->plugins[slot];UInt32 size=0;Boolean write=false;if(AudioUnitGetPropertyInfo(plugin,kAudioUnitProperty_ParameterList,kAudioUnitScope_Global,0,&size,&write))return json(a);std::vector<AudioUnitParameterID> ps(size/4);if(AudioUnitGetProperty(plugin,kAudioUnitProperty_ParameterList,kAudioUnitScope_Global,0,ps.data(),&size))return json(a);
 for(auto id:ps){AudioUnitParameterInfo info{};UInt32 n=sizeof(info);if(AudioUnitGetProperty(plugin,kAudioUnitProperty_ParameterInfo,kAudioUnitScope_Global,id,&info,&n))continue;Float32 value=0;AudioUnitGetParameter(plugin,id,kAudioUnitScope_Global,0,&value);NSString*name=(info.flags&kAudioUnitParameterFlag_HasCFNameString)&&info.cfNameString?(__bridge NSString*)info.cfNameString:[NSString stringWithUTF8String:info.name];if(info.flags&kAudioUnitParameterFlag_IsWritable)[a addObject:@{@"id":@(id),@"name":name?:@"Parameter",@"min":@(info.minValue),@"max":@(info.maxValue),@"value":@(value)}];if((info.flags&kAudioUnitParameterFlag_CFNameRelease)&&info.cfNameString)CFRelease(info.cfNameString);}
 return json(a);}}
int td_plugin_set_at(void*p,int slot,uint32_t id,float value){auto*s=(Stream*)p;return s&&slot>=0&&slot<4&&s->plugins[slot]?AudioUnitSetParameter(s->plugins[slot],id,kAudioUnitScope_Global,0,value,0):-1;}
int td_plugin(void*p,uint32_t t,uint32_t s,uint32_t m,char*e,int n){return td_plugin_at(p,0,t,s,m,e,n);}
char*td_plugin_params(void*p){return td_plugin_params_at(p,0);}
int td_plugin_set(void*p,uint32_t id,float v){return td_plugin_set_at(p,0,id,v);}
int td_selftest(){DSP d;d.gain=.5;float l=.2,r=.2;for(int i=0;i<20000;i++){l=r=.2;d.process(l,r);}if(fabs(l-.1)>.001)return 1;d.mute=true;for(int i=0;i<20000;i++){l=r=.2;d.process(l,r);}if(fabs(l)>.0001)return 2;d.mute=false;d.gain=4;d.boost=true;d.eq=true;for(int i=0;i<10;i++)d.bands[i]=12;d.update();for(int i=0;i<48000;i++){l=r=sin(i*.1);d.process(l,r);if(!std::isfinite(l)||fabs(l)>1)return 3;}return 0;}

void td_bypass(void*p,int bypass){if(p)((Stream*)p)->bypass=bypass!=0;}

int td_chain_test(){
 Stream s;s.dsp.sr=48000;s.dsp.gain=1;
 float in[960]{},out[960]{};AudioBufferList input{1,{{2,sizeof(in),in}}},output{1,{{2,sizeof(out),out}}};
 auto measure=[&](){double energy=0;for(int block=0;block<100;block++){for(int i=0;i<480;i++)in[2*i]=in[2*i+1]=0.01f*sinf(2*M_PI*1000*(block*480+i)/48000);io(0,nullptr,&input,nullptr,&output,nullptr,&s);if(block>50)for(int i=0;i<960;i++)energy+=out[i]*out[i];}return sqrt(energy);};
 double baseline=measure();char error[512]{};
 if(td_plugin_at(&s,0,0x61756678,0x6c706173,0x6170706c,error,512))return 1;
 td_plugin_set_at(&s,0,0,700);double first=measure()/baseline;
 if(td_plugin_at(&s,1,0x61756678,0x6c706173,0x6170706c,error,512))return 2;
 td_plugin_set_at(&s,1,0,700);double both=measure()/baseline;
 td_bypass(&s,1);double bypass=measure()/baseline;
 printf("Offline AU chain: one=%.5f two=%.5f bypass=%.5f\n",first,both,bypass);
 if(!(first>0&&first<0.9&&fabs(both-first*first)<.05&&fabs(bypass-1)<.001))return 3;
 td_bypass(&s,0);s.dsp.gain=volumeGain(.01f);double low=measure()/baseline;
 s.dsp.mute=true;double mute=measure();s.dsp.mute=false;s.dsp.gain=0;double zero=measure();
 printf("AU chain final fader: 1%% relative=%.8f expected=%.8f mute=%.8f zero=%.8f\n",low,both*.0001,mute,zero);
 return fabs(low/both-.0001)<.000001 && mute==0 && zero==0 ? 0:4;
}

// An input-only, unmuted tap for activity detection. It never routes audio,
// changes the default device, records a file, or feeds samples to an output.
struct ActivityMonitor {
 AudioObjectID tap=0,device=0;AudioDeviceIOProcID proc=nullptr;bool started=false;
 std::atomic<uint64_t> lastAudible{0},frames{0};
 ~ActivityMonitor(){if(started)AudioDeviceStop(device,proc);if(proc)AudioDeviceDestroyIOProcID(device,proc);if(device)AudioHardwareDestroyAggregateDevice(device);if(tap)AudioHardwareDestroyProcessTap(tap);}
};
static OSStatus activity_io(AudioObjectID,const AudioTimeStamp*,const AudioBufferList*in,const AudioTimeStamp*,AudioBufferList*,const AudioTimeStamp*,void*ref){
 auto*m=(ActivityMonitor*)ref;if(!in)return noErr;float peak=0;uint64_t samples=0;
 for(UInt32 b=0;b<in->mNumberBuffers;b++){auto &buffer=in->mBuffers[b];if(!buffer.mData)continue;const float*p=(const float*)buffer.mData;UInt32 count=buffer.mDataByteSize/sizeof(float);for(UInt32 i=0;i<count;i++){float v=fabsf(p[i]);if(std::isfinite(v))peak=std::max(peak,v);}samples+=count;}
 m->frames.fetch_add(samples,std::memory_order_relaxed);
 if(peak>0.0005f)m->lastAudible.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW),std::memory_order_relaxed);
 return noErr;
}
void*td_monitor_start(const uint32_t*p,int count,int global,char*error,int size){@autoreleasepool{
 auto*m=new ActivityMonitor;NSMutableArray*a=[NSMutableArray array];for(int i=0;i<count;i++)[a addObject:@(p[i])];
 if(global){for(NSNumber*n in ids(1,kAudioHardwarePropertyProcessObjectList))if(get<pid_t>(n.unsignedIntValue,kAudioProcessPropertyPID,0)==getpid())[a addObject:n];}
 CATapDescription*d=global?[[CATapDescription alloc]initStereoGlobalTapButExcludeProcesses:a]:[[CATapDescription alloc]initStereoMixdownOfProcesses:a];d.name=@"声控台活动检测";d.privateTap=YES;d.muteBehavior=CATapUnmuted;
 OSStatus status=AudioHardwareCreateProcessTap(d,&m->tap);if(status){err(error,size,"无法检测音频活动",status);delete m;return nullptr;}
 NSDictionary*desc=@{@kAudioAggregateDeviceNameKey:@"ToneDesk Activity",@kAudioAggregateDeviceUIDKey:[@"ToneDesk.Activity." stringByAppendingString:NSUUID.UUID.UUIDString],@kAudioAggregateDeviceIsPrivateKey:@YES,@kAudioAggregateDeviceIsStackedKey:@NO,@kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:d.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}],@kAudioAggregateDeviceTapAutoStartKey:@YES};
 status=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)desc,&m->device);if(status){err(error,size,"无法建立活动检测",status);delete m;return nullptr;}
 for(NSNumber*n in ids(m->device,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeInput)){auto f=get<AudioStreamBasicDescription>(n.unsignedIntValue,kAudioStreamPropertyVirtualFormat);if(f.mFormatID!=kAudioFormatLinearPCM||!(f.mFormatFlags&kAudioFormatFlagIsFloat)||f.mBitsPerChannel!=32){err(error,size,"活动检测不支持当前音频格式",-2);delete m;return nullptr;}}
 status=AudioDeviceCreateIOProcID(m->device,activity_io,m,&m->proc);if(!status)status=AudioDeviceStart(m->device,m->proc);if(status){err(error,size,"启动活动检测失败",status);delete m;return nullptr;}m->started=true;return m;
}}
int td_monitor_recent(void*p,int milliseconds){if(!p)return 0;auto*m=(ActivityMonitor*)p;auto last=m->lastAudible.load(std::memory_order_relaxed);return last&&clock_gettime_nsec_np(CLOCK_UPTIME_RAW)-last<uint64_t(std::max(milliseconds,0))*1000000ULL;}
uint64_t td_monitor_frames(void*p){return p?((ActivityMonitor*)p)->frames.load(std::memory_order_relaxed):0;}
void td_monitor_stop(void*p){delete (ActivityMonitor*)p;}
