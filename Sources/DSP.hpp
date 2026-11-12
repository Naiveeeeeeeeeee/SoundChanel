#pragma once
#include <atomic>
#include <cmath>
#include <algorithm>
// UI values remain 0...2 (0...200%). Below unity use an audio taper;
// preserve the existing 100% unity and 200% (+6 dB) endpoints.
inline float volumeGain(float value){
 if(!std::isfinite(value))return 0;
 value=std::clamp(value,0.f,2.f);
 return value<=1 ? value*value : value;
}
struct Biquad {
 double b0=1,b1=0,b2=0,a1=0,a2=0,z1[2]{},z2[2]{};
 void peak(double hz,double db,double sr){
  hz=std::min(hz,sr*.45);double A=pow(10,db/40),w=2*M_PI*hz/sr,alpha=sin(w)/2,den=1+alpha/A;
  b0=(1+alpha*A)/den;b1=-2*cos(w)/den;b2=(1-alpha*A)/den;a1=b1;a2=(1-alpha/A)/den;
 }
 float run(float x,int c){double y=b0*x+z1[c];z1[c]=b1*x-a1*y+z2[c];z2[c]=b2*x-a2*y;return (float)y;}
};
struct DSP {
 std::atomic<float> gain{1},balance{0},bands[10];std::atomic<bool> mute{false},boost{false},eq{false};
 Biquad filters[10];float oldBands[10];float envelope=0, limiter=1;double smoothed=0,sr=48000;
 DSP(){for(int i=0;i<10;i++){bands[i]=0;oldBands[i]=999;}}
 void update(){static double hz[]={31.25,62.5,125,250,500,1000,2000,4000,8000,16000};for(int i=0;i<10;i++){float b=bands[i].load();if(b!=oldBands[i]){filters[i].peak(hz[i],b,sr);oldBands[i]=b;}}}
 void processEffects(float &l,float &r){
  if(!std::isfinite(l))l=0;if(!std::isfinite(r))r=0;
  if(eq.load(std::memory_order_relaxed)){for(auto &f:filters){l=f.run(l,0);r=f.run(r,1);}}
  if(boost.load()){float peak=std::max(fabs(l),fabs(r));envelope+=(peak-envelope)*(peak>envelope?.02:.0003);float compression=envelope>.2?pow(envelope/.2,-.65):1;l*=compression*1.8;r*=compression*1.8;}
 }
 // The final fader follows every effect, including AU plugins, so compression
 // or automatic makeup gain cannot undo attenuation or generate sound at mute.
 void processOutput(float &l,float &r){
  float target=mute.load()?0:gain.load();
  if(!std::isfinite(target))target=0;
  smoothed+=(target-smoothed)*.002;
  if(fabs(target-smoothed)<1e-9)smoothed=target;
  float bal=balance.load();l*=smoothed*(bal>0?1-bal:1);r*=smoothed*(bal<0?1+bal:1);
  if(smoothed==0){l=r=0;return;}
  if(!std::isfinite(l))l=0;if(!std::isfinite(r))r=0;
  float peak=std::max(fabs(l),fabs(r));float want=peak>.97?.97/peak:1;limiter=want<limiter?want:limiter+(want-limiter)*.001;l*=limiter;r*=limiter;
 }
 void process(float &l,float &r){processEffects(l,r);processOutput(l,r);}
};
