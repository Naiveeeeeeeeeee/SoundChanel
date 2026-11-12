#ifndef AUDIO_BRIDGE_H
#define AUDIO_BRIDGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
char *td_snapshot(void);
void td_free(char *p);
int td_default(uint32_t device,int kind);
int td_volume(uint32_t device,int input,float volume);
int td_mute(uint32_t device,int input,int mute);
int td_rate(uint32_t device,double rate);
void *td_start(const uint32_t *processes,int count,int global,uint32_t output,char *error,int errorSize);
void *td_start_configured(const uint32_t *processes,int count,int global,uint32_t output,float gain,int mute,float balance,int boost,int eq,const float *bands,char *error,int errorSize);
float td_volume_gain(float value);
void td_stop(void *stream);
void td_params(void *stream,float volume,int mute,float balance,int boost,int eq,const float *bands);
void td_bypass(void *stream,int bypass);
float td_peak(void *stream);
float td_render_peak(void *stream);
uint64_t td_output_frames(void *stream);
int td_health(void *stream);
uint64_t td_frames(void *stream);
char *td_plugins(void);
int td_plugin(void *stream,uint32_t type,uint32_t subtype,uint32_t manufacturer,char *error,int size);
char *td_plugin_params(void *stream);
int td_plugin_set(void *stream,uint32_t parameter,float value);
int td_plugin_at(void *stream,int slot,uint32_t type,uint32_t subtype,uint32_t manufacturer,char *error,int size);
char *td_plugin_params_at(void *stream,int slot);
int td_plugin_set_at(void *stream,int slot,uint32_t parameter,float value);
int td_chain_test(void);
int td_selftest(void);
void *td_monitor_start(const uint32_t *processes,int count,int global,char *error,int size);
int td_monitor_recent(void *monitor,int milliseconds);
uint64_t td_monitor_frames(void *monitor);
void td_monitor_stop(void *monitor);
#ifdef __cplusplus
}
#endif
#endif
