#pragma once
#include <atomic>
#include <algorithm>
#include <cstdint>
#include <cmath>

// One capture producer and one native-output consumer. No locks or allocation
// in either callback. The tap and destination can have different clocks.
struct AudioRing {
 static constexpr uint64_t capacity=32768,mask=capacity-1;
 float left[capacity]{},right[capacity]{};
 std::atomic<uint64_t> written{0},read{0},underruns{0},overruns{0};
 double fraction=0,ratio=1;
 uint64_t target=1024;
 bool primed=false;
 void configure(double inputRate,double outputRate,uint64_t bufferFrames){
  ratio=inputRate/outputRate;
  target=std::clamp<uint64_t>(uint64_t(bufferFrames*ratio)*3,512,8192);
 }
 bool push(const float*l,const float*r,uint32_t count){
  auto w=written.load(std::memory_order_relaxed),rd=read.load(std::memory_order_acquire);
  if(count>capacity-(w-rd)){overruns.fetch_add(1,std::memory_order_relaxed);return false;}
  for(uint32_t i=0;i<count;i++){left[(w+i)&mask]=l[i];right[(w+i)&mask]=r[i];}
  written.store(w+count,std::memory_order_release);return true;
 }
 void render(float*l,float*r,uint32_t count){
  auto rd=read.load(std::memory_order_relaxed),w=written.load(std::memory_order_acquire);
  if(!primed){if(w-rd<target){std::fill_n(l,count,0);std::fill_n(r,count,0);return;}primed=true;}
  // Ignore ordinary callback scheduling jitter; gently correct only sustained
  // clock drift outside a two-buffer dead zone, without changing unity gain.
  double error=double(w-rd)-double(target);
  double dead=std::max(512.0,double(target)*.66);
  double correction=std::abs(error)>dead ? std::clamp((error-std::copysign(dead,error))/double(capacity)*.01,-.002,.002):0;
  double step=ratio*(1+correction);
  uint32_t i=0;
  for(;i<count;i++){
   if(rd+1>=w)break;
   auto a=rd&mask,b=(rd+1)&mask;
   l[i]=left[a]+float(fraction)*(left[b]-left[a]);r[i]=right[a]+float(fraction)*(right[b]-right[a]);
   fraction+=step;auto advance=uint64_t(fraction);fraction-=advance;
   // A downsampling step can skip beyond the final available source frame.
   // Never publish a read cursor beyond written: unsigned distance arithmetic
   // would otherwise wrap and let a later callback replay stale samples.
   if(advance>w-rd){rd=w;fraction=0;}else{rd+=advance;}
  }
  if(i<count){std::fill(l+i,l+count,0);std::fill(r+i,r+count,0);primed=false;fraction=0;underruns.fetch_add(1,std::memory_order_relaxed);}
  read.store(rd,std::memory_order_release);
 }
};
