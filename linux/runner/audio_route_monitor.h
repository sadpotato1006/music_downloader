#ifndef QINGTING_AUDIO_ROUTE_MONITOR_H
#define QINGTING_AUDIO_ROUTE_MONITOR_H

#include <flutter_linux/flutter_linux.h>
#include <pulse/glib-mainloop.h>
#include <pulse/pulseaudio.h>
#include <map>
#include <set>
#include <string>

class AudioRouteMonitor {
 public:
  explicit AudioRouteMonitor(FlBinaryMessenger* messenger);
  ~AudioRouteMonitor();

 private:
  void Connect();
  void Schedule();
  void Refresh();
  void PartDone();
  void Pause();
  static void StateChanged(pa_context*, void*);
  static void Subscription(pa_context*, pa_subscription_event_type_t, uint32_t, void*);
  static void Sink(pa_context*, const pa_sink_info*, int, void*);
  static void Input(pa_context*, const pa_sink_input_info*, int, void*);
  FlMethodChannel* channel_ = nullptr;
  pa_glib_mainloop* loop_ = nullptr;
  pa_context* context_ = nullptr;
  guint refresh_timer_ = 0, reconnect_timer_ = 0;
  int pending_ = 0;
  bool dirty_ = false, primed_ = false, snapshot_failed_ = false;
  std::map<uint32_t, std::pair<std::string, bool>> sinks_;
  std::set<uint32_t> inputs_;
  std::set<std::string> active_bluetooth_;
};

#endif
